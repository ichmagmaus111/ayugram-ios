import Foundation

// AYG: The store behind AyuGram's "Save Edits History".
//
// Ported from the source fork's `AntiDelete/EditHistoryManager.swift`. It keeps
// the text a message had *before* each edit, keyed "peerId_messageId"; the edit
// hook in `AccountStateManagementUtils.swift` calls `saveOriginalText` from
// inside the postbox transaction that is about to overwrite the message.
public final class EditHistoryManager {
    public static let shared = EditHistoryManager()

    /// Posted whenever the store mutates through clear/import, so a history
    /// screen can refresh. Ordinary captures do not post: they happen on the
    /// postbox queue, dozens at a time, and the chat view redraws anyway.
    public static let historyChangedNotification = Notification.Name("AYG.editHistoryChanged")

    private let historyKey = "AYG.editHistory"
    private var editHistory: [String: [EditRecord]] = [:]
    private let lock = NSLock()
    /// Disk writes go through their own queue and NEVER run under `lock`.
    /// `UserDefaults.set` synchronously fans out `didChangeNotification`; with a
    /// main-queue observer attached, the call blocks until the main runloop
    /// turns. Under the lock that deadlocks against chat-bubble layout, which
    /// takes the same lock via `getEditHistory` on the main thread.
    private let persistQueue = DispatchQueue(label: "org.ayugram.EditHistoryManager.persist", qos: .utility)

    /// Upper bound on pending journal files. The journal drains on the next
    /// launch, so it only grows while the app is never opened; the cap keeps a
    /// pathological case from filling the App Group container.
    private static let maximumPendingJournalFiles = 2000

    public struct EditRecord: Codable, Equatable {
        public let text: String
        public let editDate: Int32

        public init(text: String, editDate: Int32) {
            self.text = text
            self.editDate = editDate
        }
    }

    private init() {
        self.loadHistory()
        if !AYGRuntimeEnvironment.isAppExtensionProcess {
            NotificationCenter.default.addObserver(forName: aygApplicationDidBecomeActiveNotificationName, object: nil, queue: nil) { [weak self] _ in
                self?.drainSharedJournalIfNeeded()
            }
            self.drainSharedJournalIfNeeded()
        }
    }

    private func messageKey(peerId: Int64, messageId: Int32) -> String {
        return "\(peerId)_\(messageId)"
    }

    // MARK: - Capture

    /// Call BEFORE the message is rewritten with its new text.
    public func saveOriginalText(peerId: Int64, messageId: Int32, originalText: String, editDate: Int32) {
        guard !originalText.isEmpty else {
            return
        }

        // An edit that arrives while the app is unloaded is processed by the
        // Notification Service Extension, whose UserDefaults is its own
        // container — persisting there would drop the original text on the
        // floor. Hand it to the App Group journal instead.
        if AYGRuntimeEnvironment.isAppExtensionProcess {
            self.appendToSharedJournal(peerId: peerId, messageId: messageId, text: originalText, editDate: editDate)
            return
        }

        let key = self.messageKey(peerId: peerId, messageId: messageId)
        self.lock.lock()
        var history = self.editHistory[key] ?? []
        guard history.last?.text != originalText else {
            self.lock.unlock()
            return
        }
        history.append(EditRecord(text: originalText, editDate: editDate))
        self.editHistory[key] = history
        let snapshot = self.editHistory
        self.lock.unlock()

        // Called from the postbox queue inside `transaction.updateMessage`.
        // Encoding and writing happen off-lock.
        self.persist(snapshot)
    }

    // MARK: - Reads

    public func getEditHistory(peerId: Int64, messageId: Int32) -> [EditRecord] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.editHistory[self.messageKey(peerId: peerId, messageId: messageId)] ?? []
    }

    public func hasEditHistory(peerId: Int64, messageId: Int32) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return !(self.editHistory[self.messageKey(peerId: peerId, messageId: messageId)]?.isEmpty ?? true)
    }

    /// One message's worth of history, for UI iteration.
    public struct EditedMessageHistory: Equatable {
        public let peerId: Int64
        public let messageId: Int32
        public let records: [EditRecord]

        public init(peerId: Int64, messageId: Int32, records: [EditRecord]) {
            self.peerId = peerId
            self.messageId = messageId
            self.records = records
        }

        public var lastEditDate: Int32 {
            return self.records.map({ $0.editDate }).max() ?? 0
        }

        public var latestOriginalText: String {
            return self.records.max(by: { $0.editDate < $1.editDate })?.text ?? ""
        }
    }

    public func getAllEditedMessages() -> [EditedMessageHistory] {
        self.lock.lock()
        let snapshot = self.editHistory
        self.lock.unlock()

        var result: [EditedMessageHistory] = []
        for (key, records) in snapshot where !records.isEmpty {
            let parts = key.split(separator: "_", maxSplits: 1).map(String.init)
            guard parts.count == 2, let peerId = Int64(parts[0]), let messageId = Int32(parts[1]) else {
                continue
            }
            result.append(EditedMessageHistory(peerId: peerId, messageId: messageId, records: records))
        }
        result.sort { $0.lastEditDate > $1.lastEditDate }
        return result
    }

    public func getEditedMessages(forPeerId peerId: Int64) -> [EditedMessageHistory] {
        return self.getAllEditedMessages().filter { $0.peerId == peerId }
    }

    public var archivedCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.editHistory.values.filter({ !$0.isEmpty }).count
    }

    // MARK: - Mutation

    public func clearHistory(peerId: Int64, messageId: Int32) {
        let key = self.messageKey(peerId: peerId, messageId: messageId)
        self.lock.lock()
        self.editHistory.removeValue(forKey: key)
        let snapshot = self.editHistory
        self.lock.unlock()
        self.persist(snapshot)
    }

    public func clearAllHistory() {
        self.lock.lock()
        self.editHistory.removeAll()
        self.lock.unlock()
        self.persist([:])
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: EditHistoryManager.historyChangedNotification, object: nil)
        }
    }

    // MARK: - Export / import

    /// Same wire format as the deleted-message archive: readable HTML table plus
    /// the exact JSON in a `<script type="application/json">` block.
    public func exportHistoryData() -> Data? {
        self.lock.lock()
        let snapshot = self.editHistory
        self.lock.unlock()

        guard let json = try? JSONEncoder().encode(snapshot), let jsonString = String(data: json, encoding: .utf8) else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        var rows = ""
        for (key, records) in snapshot.sorted(by: { ($0.value.last?.editDate ?? 0) > ($1.value.last?.editDate ?? 0) }) where !records.isEmpty {
            for record in records.sorted(by: { $0.editDate < $1.editDate }) {
                let date = Date(timeIntervalSince1970: TimeInterval(record.editDate))
                rows += "<tr><td>\(formatter.string(from: date))</td><td>\(AntiDeleteManager.htmlEscape(key))</td><td>\(AntiDeleteManager.htmlEscape(record.text))</td></tr>\n"
            }
        }
        let safePayload = jsonString.replacingOccurrences(of: "</", with: "<\\/")
        let html = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <title>AyuGram — message edit history</title>
        <style>
        body{font:14px/1.4 -apple-system,BlinkMacSystemFont,Helvetica,Arial,sans-serif;padding:20px;background:#fafafa;color:#222}
        h1{font-size:18px;margin-bottom:4px}
        .meta{color:#666;margin-bottom:16px}
        table{border-collapse:collapse;width:100%;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.06)}
        th,td{padding:8px 10px;border-bottom:1px solid #eee;text-align:left;vertical-align:top}
        th{background:#f3f3f3;font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.04em}
        td{font-size:13px}
        </style></head><body>
        <h1>Message edit history</h1>
        <div class="meta">Exported by AyuGram. Do not remove the <code>&lt;script id="ayugram-edit-history"&gt;</code> block — it is what the import reads.</div>
        <table><thead><tr><th>Edited</th><th>Message</th><th>Text before the edit</th></tr></thead>
        <tbody>
        \(rows)</tbody></table>
        <script id="ayugram-edit-history" type="application/json">\(safePayload)</script>
        </body></html>
        """
        return html.data(using: .utf8)
    }

    /// Merge dedupes records by `editDate` per message; replace overwrites.
    @discardableResult
    public func importHistoryData(_ data: Data, merge: Bool = true) -> (addedMessages: Int, addedRecords: Int, total: Int) {
        let payload = AntiDeleteManager.extractJSONPayload(from: data)
        guard let incoming = try? JSONDecoder().decode([String: [EditRecord]].self, from: payload) else {
            return (0, 0, self.archivedCount)
        }

        var addedMessages = 0
        var addedRecords = 0
        self.lock.lock()
        if merge {
            for (key, records) in incoming where !records.isEmpty {
                var existing = self.editHistory[key] ?? []
                let isNewKey = existing.isEmpty
                let seenDates = Set(existing.map({ $0.editDate }))
                for record in records where !seenDates.contains(record.editDate) {
                    existing.append(record)
                    addedRecords += 1
                }
                if isNewKey && !existing.isEmpty {
                    addedMessages += 1
                }
                if !existing.isEmpty {
                    existing.sort { $0.editDate < $1.editDate }
                    self.editHistory[key] = existing
                }
            }
        } else {
            self.editHistory = incoming
            addedMessages = incoming.values.filter({ !$0.isEmpty }).count
            addedRecords = incoming.values.reduce(0) { $0 + $1.count }
        }
        let total = self.editHistory.values.filter({ !$0.isEmpty }).count
        let snapshot = self.editHistory
        self.lock.unlock()

        self.persist(snapshot)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: EditHistoryManager.historyChangedNotification, object: nil)
        }
        return (addedMessages, addedRecords, total)
    }

    // MARK: - Shared App Group journal (extension → main app)

    private struct PendingEdit: Codable {
        let peerId: Int64
        let messageId: Int32
        let text: String
        let editDate: Int32
    }

    private var sharedJournalDirURL: URL? {
        guard let container = AYGRuntimeEnvironment.appGroupContainerURL else {
            return nil
        }
        return container.appendingPathComponent("ayugram_pending_edited", isDirectory: true)
    }

    private func appendToSharedJournal(peerId: Int64, messageId: Int32, text: String, editDate: Int32) {
        guard let dir = self.sharedJournalDirURL else {
            return
        }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            if let existing = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
               existing.count >= EditHistoryManager.maximumPendingJournalFiles {
                return
            }
            let url = dir.appendingPathComponent("\(peerId)_\(messageId)_\(editDate).json")
            let data = try JSONEncoder().encode(PendingEdit(peerId: peerId, messageId: messageId, text: text, editDate: editDate))
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.shared.log("AYGEditHistory", "journal append failed: \(error)")
        }
    }

    public func drainSharedJournalIfNeeded() {
        guard !AYGRuntimeEnvironment.isAppExtensionProcess else {
            return
        }
        guard let dir = self.sharedJournalDirURL else {
            return
        }
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil), !files.isEmpty else {
            return
        }

        // Decode off-lock; files that fail to decode stay put, because a schema
        // change must not silently destroy captured text.
        var decoded: [(edit: PendingEdit, url: URL)] = []
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let edit = try? JSONDecoder().decode(PendingEdit.self, from: data) {
                decoded.append((edit, url))
            }
        }
        guard !decoded.isEmpty else {
            return
        }
        // Oldest first, so a message edited several times while the app was
        // closed ends up with its records in chronological order.
        decoded.sort { $0.edit.editDate < $1.edit.editDate }

        var didMerge = false
        self.lock.lock()
        for (edit, _) in decoded {
            let key = self.messageKey(peerId: edit.peerId, messageId: edit.messageId)
            var history = self.editHistory[key] ?? []
            // Same identity check the live path uses, plus the date: two edits
            // can restore identical text, and both are worth keeping.
            if history.contains(where: { $0.text == edit.text && $0.editDate == edit.editDate }) {
                continue
            }
            if history.last?.text == edit.text {
                continue
            }
            history.append(EditRecord(text: edit.text, editDate: edit.editDate))
            self.editHistory[key] = history
            didMerge = true
        }
        let snapshot = self.editHistory
        self.lock.unlock()

        for (_, url) in decoded {
            try? fileManager.removeItem(at: url)
        }

        guard didMerge else {
            return
        }
        self.persist(snapshot)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: EditHistoryManager.historyChangedNotification, object: nil)
        }
    }

    // MARK: - Persistence

    /// NEVER call under `lock` — see the note on `persistQueue`.
    private func persist(_ snapshot: [String: [EditRecord]]) {
        let historyKey = self.historyKey
        self.persistQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else {
                return
            }
            AYGSharedDefaults.store.set(data, forKey: historyKey)
        }
    }

    private func loadHistory() {
        guard let data = AYGSharedDefaults.store.data(forKey: self.historyKey) else {
            return
        }
        self.editHistory = (try? JSONDecoder().decode([String: [EditRecord]].self, from: data)) ?? [:]
    }
}
