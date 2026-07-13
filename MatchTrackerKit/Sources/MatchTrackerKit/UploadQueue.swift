import Foundation

// MARK: - Offline upload queue

/// One queued upload, persisted as a single JSON file so it survives app relaunches. `payloadJSON`
/// is the encoded body (`MatchPayload` for `.match`, `[FieldModel]` for `.fields`); the queue
/// decodes it and re-posts through `APIClient` on `flush()`.
public struct PendingUpload: Codable, Identifiable, Sendable {
    public var id: UUID
    public var kind: Kind
    public var payloadJSON: Data
    public var attempts: Int
    public var nextAttempt: Date
    public var lastError: String?

    public enum Kind: String, Codable, Sendable { case match, fields }

    public init(id: UUID, kind: Kind, payloadJSON: Data, attempts: Int = 0,
                nextAttempt: Date = Date(), lastError: String? = nil) {
        self.id = id
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.attempts = attempts
        self.nextAttempt = nextAttempt
        self.lastError = lastError
    }
}

/// A durable, retrying upload queue. Every post is written to disk first (one JSON file per
/// `PendingUpload` under `{directory}/uploads/`) so nothing is lost if the app is killed offline;
/// `flush()` drains everything due through `APIClient` with exponential backoff on failure.
///
/// Thread-safe: the in-memory `pending` snapshot is guarded by an `NSLock`.
public final class UploadQueue {
    private let directory: URL
    private let client: APIClient
    private let lock = NSLock()
    private var storage: [PendingUpload] = []

    /// Backoff is capped at six hours.
    private static let maximumBackoff: TimeInterval = 21600

    public init(directory: URL, client: APIClient) {
        self.directory = directory.appendingPathComponent("uploads", isDirectory: true)
        self.client = client
        loadPersisted()
    }

    /// Snapshot of everything currently queued (thread-safe).
    public var pending: [PendingUpload] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    // MARK: Enqueue

    /// Queue a match upload. Keyed by the match uuid, so re-enqueuing the same match replaces the
    /// prior entry (idempotent with the backend's upsert-by-uuid semantics).
    public func enqueue(match: MatchPayload) throws {
        let data = try Self.payloadEncoder.encode(match)
        try persist(PendingUpload(id: match.uuid, kind: .match, payloadJSON: data))
    }

    /// Queue a batch of field uploads under a fresh id.
    public func enqueue(fields: [FieldModel]) throws {
        let data = try Self.payloadEncoder.encode(fields)
        try persist(PendingUpload(id: UUID(), kind: .fields, payloadJSON: data))
    }

    // MARK: Flush

    /// Attempts every due item (`nextAttempt <= now`) serially, oldest first. Success removes the
    /// item and its file; failure bumps `attempts`, schedules the next attempt with exponential
    /// backoff (`60 * 2^attempts` seconds, capped at 6 h), and records `lastError`.
    /// - Returns: the number of items still queued afterward.
    @discardableResult
    public func flush() async -> Int {
        for item in dueItems(asOf: Date()) {
            do {
                switch item.kind {
                case .match:
                    let payload = try Self.payloadDecoder.decode(MatchPayload.self, from: item.payloadJSON)
                    try await client.post(matches: [payload])
                case .fields:
                    let fields = try Self.payloadDecoder.decode([FieldModel].self, from: item.payloadJSON)
                    try await client.post(fields: fields)
                }
                remove(id: item.id)
            } catch {
                recordFailure(id: item.id, error: error)
            }
        }
        return count()
    }

    /// Due items (`nextAttempt <= now`), oldest first. Synchronous so the lock never straddles an
    /// `await`.
    private func dueItems(asOf now: Date) -> [PendingUpload] {
        lock.lock()
        defer { lock.unlock() }
        return storage
            .filter { $0.nextAttempt <= now }
            .sorted { $0.nextAttempt < $1.nextAttempt }
    }

    private func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    // MARK: - Persistence

    private static let payloadEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let payloadDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func persist(_ upload: PendingUpload) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeFile(upload)
        lock.lock()
        if let index = storage.firstIndex(where: { $0.id == upload.id }) {
            storage[index] = upload
        } else {
            storage.append(upload)
        }
        lock.unlock()
    }

    private func writeFile(_ upload: PendingUpload) throws {
        let data = try Self.payloadEncoder.encode(upload)
        try data.write(to: fileURL(for: upload.id), options: .atomic)
    }

    private func remove(id: UUID) {
        lock.lock()
        storage.removeAll { $0.id == id }
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    private func recordFailure(id: UUID, error: Error) {
        lock.lock()
        guard let index = storage.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        var item = storage[index]
        item.attempts += 1
        let backoff = min(60 * pow(2, Double(item.attempts)), Self.maximumBackoff)
        item.nextAttempt = Date().addingTimeInterval(backoff)
        item.lastError = String(describing: error)
        storage[index] = item
        lock.unlock()
        try? writeFile(item)
    }

    private func loadPersisted() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        var loaded: [PendingUpload] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let upload = try? Self.payloadDecoder.decode(PendingUpload.self, from: data) {
                loaded.append(upload)
            }
        }
        loaded.sort { $0.nextAttempt < $1.nextAttempt }
        lock.lock()
        storage = loaded
        lock.unlock()
    }
}
