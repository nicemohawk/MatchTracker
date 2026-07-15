// ConnectivityManager.swift
// MatchTracker

import Foundation
import MatchTrackerKit
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Bridges WatchConnectivity: receives transferred field/match files from the watch and
/// mirrors the field list + settings back via `updateApplicationContext`.
final class ConnectivityManager: NSObject, ObservableObject {
    let fields: FieldsModel
    let settings: SettingsStore

    /// Invoked (on the main actor) when a new match record arrives so the app can refresh + upload.
    var onMatchRecordReceived: ((MatchRecord) -> Void)?
    /// Invoked (on the main actor) when a field was received and saved.
    var onFieldReceived: (() -> Void)?
    /// Invoked (on the main actor) for each live in-match update streamed from the watch.
    var onLiveUpdate: ((LiveMatchUpdate) -> Void)?

    init(fields: FieldsModel, settings: SettingsStore) {
        self.fields = fields
        self.settings = settings
        super.init()
    }

    func start() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif
    }

    /// Push the current field list + team/player settings so the watch can auto-detect fields offline.
    ///
    /// Guarded on `isPaired && isWatchAppInstalled`: without a paired watch running the counterpart
    /// app, `updateApplicationContext` fails with "WCSession counterpart app not installed" and the
    /// call is doomed. We re-push from `sessionWatchStateDidChange` once a watch actually appears, so
    /// nothing is lost — we just stop hammering when there's no receiver.
    func pushContext() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard session.isPaired, session.isWatchAppInstalled else { return }

        Task { @MainActor in
            var context: [String: Any] = [
                "teamCode": settings.teamCode,
                "playerName": settings.playerName
            ]
            if let data = fields.encodedFields() {
                context["fields"] = data
            }
            do {
                try session.updateApplicationContext(context)
            } catch {
                MatchLog.error("updateApplicationContext failed: \(error.localizedDescription)", category: "connectivity")
            }
        }
        #endif
    }
}

#if canImport(WatchConnectivity)
extension ConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated { pushContext() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    /// Pairing / watch-app-install state changed. If a usable watch just appeared, push the context
    /// we were suppressing while there was no receiver.
    func sessionWatchStateDidChange(_ session: WCSession) {
        if session.isPaired, session.isWatchAppInstalled {
            pushContext()
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let type = file.metadata?["type"] as? String
        // Copy out of the transfer sandbox synchronously before the URL is invalidated.
        let data = try? Data(contentsOf: file.fileURL)

        switch type {
        case "field":
            handleField(data: data)
        case "matchRecord":
            handleMatchRecord(data: data)
        default:
            // Best-effort: try to decode as either.
            handleField(data: data)
        }
    }

    private func handleField(data: Data?) {
        guard let data else { return }
        guard let field = try? MatchTrackerJSON.decoder().decode(FieldModel.self, from: data) else { return }
        Task { @MainActor in
            fields.save(field, pushToWatch: false)
            onFieldReceived?()
            pushContext()
            snapInferredField(field)
        }
    }

    /// Architecture contract: a GPS-inferred field received from the watch is sharpened against
    /// Apple Maps satellite imagery on-device. Best-effort and fire-and-forget — on a hit we
    /// replace the noisy rectangle with the crisp one, upgrade the source to `.satellite`, save,
    /// and mirror the updated field list back to the watch. Failures fall back silently.
    private func snapInferredField(_ field: FieldModel) {
        guard field.source == .inferred else { return }
        Task { [weak self] in
            guard let snapped = await SatelliteFieldDetector().snap(rectangle: field.rectangle) else { return }
            await MainActor.run {
                guard let self else { return }
                var updated = field
                updated.rectangle = snapped
                updated.source = .satellite
                self.fields.save(updated, pushToWatch: false)
                self.onFieldReceived?()
                self.pushContext()
            }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleLiveUpdate(message["liveUpdate"] as? Data)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleLiveUpdate(userInfo["liveUpdate"] as? Data)
    }

    private func handleLiveUpdate(_ data: Data?) {
        guard let data,
              let update = try? MatchTrackerJSON.decoder().decode(LiveMatchUpdate.self, from: data) else { return }
        Task { @MainActor in
            onLiveUpdate?(update)
        }
    }

    private func handleMatchRecord(data: Data?) {
        guard let data else { return }
        guard let record = try? MatchTrackerJSON.decoder().decode(MatchRecord.self, from: data) else { return }
        try? data.write(to: AppGroup.matchRecordURL(for: record.id), options: .atomic)
        Task { @MainActor in
            onMatchRecordReceived?(record)
        }
    }
}
#endif
