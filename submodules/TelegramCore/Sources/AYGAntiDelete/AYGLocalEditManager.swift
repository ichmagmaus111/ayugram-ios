import Foundation

// AYG: Client-side-only message edits.
//
// Ported from the source fork's `AntiDelete/LocalEditManager.swift`. Nothing
// here talks to the server: it records text the user rewrote locally, so the
// chat can render the local version while keeping the real one. Persisted to
// Documents so the edits survive a restart.
public final class LocalEditManager {
    public static let shared = LocalEditManager()

    /// "peerId_messageId" -> the local versions, oldest first.
    private var edits: [String: [String]] = [:]
    private let lock = NSLock()
    /// Disk writes go through their own queue and NEVER run under `lock`: the
    /// same lock is taken by chat-bubble layout on the main thread
    /// (`getLocalEdits`), and holding it across a file write is a ready-made
    /// hang.
    private let persistQueue = DispatchQueue(label: "org.ayugram.LocalEditManager.persist", qos: .utility)

    private var storageURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("ayugram_local_edits.json")
    }

    private init() {
        self.loadEdits()
    }

    // MARK: - Public API

    public func setLocalEdit(peerId: Int64, messageId: Int32, newText: String) {
        let key = self.makeKey(peerId: peerId, messageId: messageId)
        self.lock.lock()
        var history = self.edits[key] ?? []
        if history.last != newText {
            history.append(newText)
        }
        self.edits[key] = history
        let snapshot = self.edits
        self.lock.unlock()

        self.persist(snapshot)
    }

    /// The most recent local version, or nil when the message was never edited.
    public func getLocalEdit(peerId: Int64, messageId: Int32) -> String? {
        let key = self.makeKey(peerId: peerId, messageId: messageId)
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.edits[key]?.last
    }

    public func getLocalEdits(peerId: Int64, messageId: Int32) -> [String] {
        let key = self.makeKey(peerId: peerId, messageId: messageId)
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.edits[key] ?? []
    }

    public func hasLocalEdit(peerId: Int64, messageId: Int32) -> Bool {
        let key = self.makeKey(peerId: peerId, messageId: messageId)
        self.lock.lock()
        defer { self.lock.unlock() }
        return !(self.edits[key] ?? []).isEmpty
    }

    public func removeLocalEdit(peerId: Int64, messageId: Int32) {
        let key = self.makeKey(peerId: peerId, messageId: messageId)
        self.lock.lock()
        self.edits.removeValue(forKey: key)
        let snapshot = self.edits
        self.lock.unlock()

        self.persist(snapshot)
    }

    public func clearAllEdits() {
        self.lock.lock()
        self.edits.removeAll()
        self.lock.unlock()

        self.persist([:])
    }

    public var editCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.edits.count
    }

    // MARK: - Private

    private func makeKey(peerId: Int64, messageId: Int32) -> String {
        return "\(peerId)_\(messageId)"
    }

    /// NEVER call under `lock` — see the note on `persistQueue`.
    private func persist(_ snapshot: [String: [String]]) {
        let url = self.storageURL
        self.persistQueue.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                Logger.shared.log("AYGLocalEdit", "failed to save: \(error)")
            }
        }
    }

    private func loadEdits() {
        guard let data = try? Data(contentsOf: self.storageURL) else {
            return
        }
        self.edits = (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }
}
