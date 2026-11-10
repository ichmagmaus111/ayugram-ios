import Foundation
import Postbox

// AYG: The two Spy rows the source fork does not have — "Save Read Date" and
// "Save Last Seen Date". Written against AyuGram for Android's own
// `AyuSpyController`, which is where the behaviour is defined:
//
//   onMessageRead(dialogId, maxId)  -> a SpyMessageRead row per message, holding
//                                     the local clock at the moment the read
//                                     arrived. Read back when Telegram declines
//                                     to tell you when your message was read.
//   saveOnlineActivity(userId, ts)  -> a SpyLastSeen row, but only for users
//                                     whose status is "bad" (recently / last
//                                     week / last month / hidden). Someone with
//                                     a visible status needs no reconstruction.
//
// Two deliberate differences from Android:
//
//   * Read dates are stored as (maxReadId, date) checkpoints per peer rather
//     than one row per message. Telegram's read-outbox update *is* a watermark —
//     "everything up to N is read" — so a row per message would store the same
//     date N times and answer exactly the same question.
//   * Last-seen leans on data Telegram-iOS already collects.
//     `replayFinalState` builds `peerActivityTimestamps` from incoming messages
//     and read receipts and hands it to `updatePeerPresenceLastActivities`,
//     which writes `TelegramUserPresence.lastActivity` — but the next presence
//     update from the server overwrites that wholesale. So the same timestamps
//     are mirrored here, where they survive.
public final class SpyDataStore {
    public static let shared = SpyDataStore()

    public static let dataChangedNotification = Notification.Name("AYG.spyDataChanged")

    private let defaults = AYGSharedDefaults.store
    private let saveReadDateKey = "AYG.spy.saveReadDate"
    private let saveLastSeenDateKey = "AYG.spy.saveLastSeenDate"

    /// Keeps the file bounded. A checkpoint is ~20 bytes; these caps put the
    /// worst case in the low megabytes.
    private static let maximumPeers = 4000
    private static let maximumCheckpointsPerPeer = 128

    private struct ReadCheckpoint: Codable, Equatable {
        let maxReadId: Int32
        let date: Int32
    }

    private struct Storage: Codable {
        var readCheckpoints: [String: [ReadCheckpoint]]
        var lastSeen: [String: Int32]

        init() {
            self.readCheckpoints = [:]
            self.lastSeen = [:]
        }
    }

    private var storage = Storage()
    private let lock = NSLock()
    /// Same rule as the other managers: never write to disk under `lock`, which
    /// the UI takes on the main thread.
    private let persistQueue = DispatchQueue(label: "org.ayugram.SpyDataStore.persist", qos: .utility)
    private var persistScheduled = false

    private var storageURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("ayugram_spy_data.json")
    }

    private init() {
        self.load()
    }

    // MARK: - Settings

    /// AyuGram default: off.
    public var saveReadDate: Bool {
        get { return self.defaults.bool(forKey: self.saveReadDateKey) }
        set {
            self.defaults.set(newValue, forKey: self.saveReadDateKey)
            NotificationCenter.default.post(name: SpyDataStore.dataChangedNotification, object: nil)
        }
    }

    /// AyuGram default: off.
    public var saveLastSeenDate: Bool {
        get { return self.defaults.bool(forKey: self.saveLastSeenDateKey) }
        set {
            self.defaults.set(newValue, forKey: self.saveLastSeenDateKey)
            NotificationCenter.default.post(name: SpyDataStore.dataChangedNotification, object: nil)
        }
    }

    // MARK: - Read dates

    /// The peer has read everything up to `maxReadId`. `date` is the server's
    /// own read date when it supplied one, otherwise the local clock — which is
    /// the whole point of the feature.
    public func recordOutgoingRead(peerId: Int64, maxReadId: Int32, date: Int32) {
        guard self.saveReadDate else {
            return
        }
        let key = "\(peerId)"
        self.lock.lock()
        var checkpoints = self.storage.readCheckpoints[key] ?? []
        if let last = checkpoints.last, last.maxReadId >= maxReadId {
            self.lock.unlock()
            return
        }
        checkpoints.append(ReadCheckpoint(maxReadId: maxReadId, date: date))
        if checkpoints.count > SpyDataStore.maximumCheckpointsPerPeer {
            checkpoints.removeFirst(checkpoints.count - SpyDataStore.maximumCheckpointsPerPeer)
        }
        self.storage.readCheckpoints[key] = checkpoints
        if self.storage.readCheckpoints.count > SpyDataStore.maximumPeers {
            self.evictOldestPeerLocked()
        }
        self.lock.unlock()
        self.schedulePersist()
    }

    /// When this message was known to have been read, or nil if we never saw a
    /// read receipt covering it.
    public func readDate(peerId: Int64, messageId: Int32) -> Int32? {
        guard self.saveReadDate else {
            return nil
        }
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let checkpoints = self.storage.readCheckpoints["\(peerId)"] else {
            return nil
        }
        // Checkpoints are appended in increasing `maxReadId`, so the first one
        // that covers the message is also the tightest bound on when it was read.
        for checkpoint in checkpoints where checkpoint.maxReadId >= messageId {
            return checkpoint.date
        }
        return nil
    }

    // MARK: - Last seen

    /// Only call for a user whose status is hidden — see `isHiddenStatus`.
    public func recordLastSeen(peerId: Int64, timestamp: Int32) {
        guard self.saveLastSeenDate else {
            return
        }
        // Telegram's own epoch floor; anything earlier is a bogus sentinel.
        guard timestamp >= 1397411401 else {
            return
        }
        let key = "\(peerId)"
        self.lock.lock()
        if let existing = self.storage.lastSeen[key], existing >= timestamp {
            self.lock.unlock()
            return
        }
        self.storage.lastSeen[key] = timestamp
        self.lock.unlock()
        self.schedulePersist()
    }

    public func lastSeen(peerId: Int64) -> Int32? {
        guard self.saveLastSeenDate else {
            return nil
        }
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage.lastSeen["\(peerId)"]
    }

    /// AyuGram's `AyuSpyController.isBadStatus`: the statuses that hide the real
    /// last-seen time and are therefore worth reconstructing.
    public static func isHiddenStatus(_ presence: TelegramUserPresence?) -> Bool {
        guard let presence = presence else {
            return true
        }
        switch presence.status {
        case .present, .none:
            return false
        case .recently, .lastWeek, .lastMonth:
            return true
        }
    }

    // MARK: - Housekeeping

    public var recordedPeerCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return Set(self.storage.readCheckpoints.keys).union(self.storage.lastSeen.keys).count
    }

    public func clear() {
        self.lock.lock()
        self.storage = Storage()
        self.lock.unlock()
        self.schedulePersist()
        NotificationCenter.default.post(name: SpyDataStore.dataChangedNotification, object: nil)
    }

    /// Must be called while holding `lock`. Drops the peer whose newest
    /// checkpoint is oldest — the one least likely to still be on screen.
    private func evictOldestPeerLocked() {
        var oldestKey: String?
        var oldestDate = Int32.max
        for (key, checkpoints) in self.storage.readCheckpoints {
            let date = checkpoints.last?.date ?? 0
            if date < oldestDate {
                oldestDate = date
                oldestKey = key
            }
        }
        if let oldestKey = oldestKey {
            self.storage.readCheckpoints.removeValue(forKey: oldestKey)
        }
    }

    // MARK: - Persistence

    /// Coalesced: a burst of read receipts is one write, not one per message.
    private func schedulePersist() {
        self.lock.lock()
        if self.persistScheduled {
            self.lock.unlock()
            return
        }
        self.persistScheduled = true
        self.lock.unlock()

        self.persistQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else {
                return
            }
            self.lock.lock()
            self.persistScheduled = false
            let snapshot = self.storage
            self.lock.unlock()

            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: self.storageURL, options: .atomic)
            } catch {
                Logger.shared.log("AYGSpyData", "failed to save: \(error)")
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: self.storageURL) else {
            return
        }
        self.storage = (try? JSONDecoder().decode(Storage.self, from: data)) ?? Storage()
    }
}

// MARK: - Hooks

/// Called from the `.ReadOutbox` branch of the account update replay.
func aygRecordOutgoingRead(messageId: MessageId, timestamp: Int32?) {
    guard SpyDataStore.shared.saveReadDate else {
        return
    }
    // Only private chats: a group's read state is per-member and the update
    // carries no author, so there is nothing to attribute.
    guard messageId.peerId.namespace == Namespaces.Peer.CloudUser else {
        return
    }
    SpyDataStore.shared.recordOutgoingRead(
        peerId: messageId.peerId.toInt64(),
        maxReadId: messageId.id,
        date: timestamp ?? Int32(Date().timeIntervalSince1970)
    )
}

/// Called from the replay's tail, alongside `updatePeerPresenceLastActivities`,
/// with the very same activity timestamps.
func aygRecordPeerActivityTimestamps(transaction: Transaction, accountPeerId: PeerId, activities: [PeerId: Int32]) {
    guard SpyDataStore.shared.saveLastSeenDate else {
        return
    }
    for (peerId, timestamp) in activities {
        guard peerId != accountPeerId, peerId.namespace == Namespaces.Peer.CloudUser else {
            continue
        }
        if let user = transaction.getPeer(peerId) as? TelegramUser, user.botInfo != nil {
            continue
        }
        // Only users who hide their real last-seen; for everyone else Telegram
        // already shows it and a local copy would only go stale.
        guard SpyDataStore.isHiddenStatus(transaction.getPeerPresence(peerId: peerId) as? TelegramUserPresence) else {
            continue
        }
        SpyDataStore.shared.recordLastSeen(peerId: peerId.toInt64(), timestamp: timestamp)
    }
}
