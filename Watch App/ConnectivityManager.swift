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
        guard let url = writeTemporaryJSON(matchRecord, prefix: "match") else { return }
        WCSession.default.transferFile(url, metadata: [TransferType.key: TransferType.matchRecord])
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

    private func apply(context: [String: Any]) {
        if let fieldsData = context[ContextKey.fields] as? Data,
           let fields = try? MatchTrackerJSON.decoder().decode([FieldModel].self, from: fieldsData) {
            replaceStoredFields(with: fields)
        }
        if let teamCode = context[ContextKey.teamCode] as? String {
            AppGroupStorage.teamCode = teamCode
            self.teamCode = teamCode
        }
        if let playerName = context[ContextKey.playerName] as? String {
            AppGroupStorage.playerName = playerName
            self.playerName = playerName
        }
    }

    /// Replace the local field store contents with the phone's authoritative list.
    private func replaceStoredFields(with fields: [FieldModel]) {
        let store = AppGroupStorage.fieldStore
        for existing in store.fields where !fields.contains(where: { $0.id == existing.id }) {
            try? store.delete(id: existing.id)
        }
        for field in fields {
            try? store.save(field)
        }
        fieldsRevision += 1
    }
}

// MARK: - WCSessionDelegate

extension ConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        let context = session.receivedApplicationContext
        guard !context.isEmpty else { return }
        DispatchQueue.main.async {
            self.apply(context: context)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            self.apply(context: applicationContext)
        }
    }

    /// Clean up the temporary JSON file backing a completed transfer. On success the file has
    /// been delivered and can be removed; on failure it is left in place so WCSession can retry.
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if error == nil {
            try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        }
    }
}
