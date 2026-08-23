//
//  ConnectivityManager.swift
//  MatchTracker
//

import Foundation
import Observation
import WatchConnectivity
import MatchTrackerKit

/// Bridges the watch to the phone over `WCSession`.
///
/// Inbound: the phone mirrors the field database, team code and player name via
/// `applicationContext`. Outbound: newly trained/inferred fields and finished match records are
/// pushed with `transferFile` (WCSession queues these when the phone is unreachable, so nothing
/// is dropped).
@Observable
final class ConnectivityManager: NSObject {
    static let shared = ConnectivityManager()

    /// Bumped whenever the mirrored field list changes so views can refresh field detection.
    var fieldsRevision = 0
    var teamCode: String? = AppGroupStorage.teamCode
    var playerName: String? = AppGroupStorage.playerName

    enum ContextKey {
        static let fields = "fields"
        static let teamCode = "teamCode"
        static let playerName = "playerName"
    }

    enum TransferType {
        static let key = "type"
        static let field = "field"
        static let matchRecord = "matchRecord"
        static let journal = "journal"
    }

    /// Ship the watch's lifecycle journal to the phone (called after each match ends) so a
    /// phone-side diagnostic export can reconstruct what happened on the watch.
    func sendJournal() {
        guard WCSession.default.activationState == .activated else { return }
        DispatchQueue.global(qos: .utility).async {
            MatchLog.flushJournal()
            let journalURL = AppGroupStorage.containerURL.appendingPathComponent("journal-watch.jsonl")
            guard let data = try? Data(contentsOf: journalURL), !data.isEmpty else { return }
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("journal-\(UUID().uuidString).jsonl")
            guard (try? data.write(to: temp, options: .atomic)) != nil else { return }
            WCSession.default.transferFile(temp, metadata: [TransferType.key: TransferType.journal])
        }
    }

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Outbound transfers

    func send(field: FieldModel) {
        guard let url = writeTemporaryJSON(field, prefix: "field") else { return }
        WCSession.default.transferFile(url, metadata: [TransferType.key: TransferType.field])
    }

    func send(matchRecord: MatchRecord) {
        // Encode + temp-file write off the main queue: this fires from the summary's onAppear,
        // right as its celebration animates in. transferFile itself just enqueues.
        DispatchQueue.global(qos: .utility).async {
            guard let url = self.writeTemporaryJSON(matchRecord, prefix: "match") else { return }
            WCSession.default.transferFile(url, metadata: [TransferType.key: TransferType.matchRecord])
        }
    }

    private func writeTemporaryJSON<T: Encodable>(_ value: T, prefix: String) -> URL? {
        guard let data = try? MatchTrackerJSON.encoder().encode(value) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Inbound context

    /// Called on WCSession's background queue: the JSON decode (the expensive part of a mirror)
    /// stays here, and only the store/UI updates hop to main.
    private func apply(context: [String: Any]) {
        let decodedFields = (context[ContextKey.fields] as? Data)
            .flatMap { try? MatchTrackerJSON.decoder().decode([FieldModel].self, from: $0) }
        let teamCode = context[ContextKey.teamCode] as? String
        let playerName = context[ContextKey.playerName] as? String
        DispatchQueue.main.async {
            if let decodedFields {
                self.replaceStoredFields(with: decodedFields)
            }
            if let teamCode {
                AppGroupStorage.teamCode = teamCode
                self.teamCode = teamCode
            }
            if let playerName {
                AppGroupStorage.playerName = playerName
                self.playerName = playerName
            }
        }
    }

    /// Replace the local field store contents with the phone's authoritative list: one persist
    /// for the whole list, and only when it actually changed — a no-op mirror must not bump
    /// `fieldsRevision` and retrigger the start screen's location lookup.
    private func replaceStoredFields(with fields: [FieldModel]) {
        let store = AppGroupStorage.fieldStore
        guard fields != store.fields else { return }
        try? store.replaceAll(fields)
        fieldsRevision += 1
    }
}

// MARK: - WCSessionDelegate

extension ConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        // Ship the journal on every launch, not just after a match. A session that ended badly —
        // a freeze cleared with a force quit — never reaches the summary, so the journal worth
        // reading is exactly the one that used to stay stranded on the watch.
        if activationState == .activated { sendJournal() }
        let context = session.receivedApplicationContext
        guard !context.isEmpty else { return }
        apply(context: context)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(context: applicationContext)
    }

    /// Clean up the temporary JSON file backing a completed transfer. On success the file has
    /// been delivered and can be removed; on failure it is left in place so WCSession can retry.
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if error == nil {
            try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        }
    }
}
