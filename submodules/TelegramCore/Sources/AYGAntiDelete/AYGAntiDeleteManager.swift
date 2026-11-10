import Foundation
import Postbox

// AYG: The capture engine behind AyuGram's "Save Deleted Messages".
//
// Ported from the source fork's `TelegramCore/Sources/AntiDelete/AntiDeleteManager.swift`,
// with all of that fork's own infrastructure removed: no remote feature
// toggles, no paid-access gate, no network, no obfuscated endpoints. What is
// left is a singleton with `UserDefaults` settings under the `AYG.` prefix and
// a JSON archive on disk.
//
// Two jobs:
//   1. Decide, on every deletion Telegram hands us, whether to keep the message.
//      Callers use `shouldCapture` / `isMessageExcluded` for that.
//   2. Keep a *separate* record of what was kept (`ArchivedMessage`), so the
//      text survives even when the postbox row eventually goes away — an
//      account being logged out, a cache purge, a secret chat rekey.
//
// Threading: every mutable field sits behind its own lock. Disk writes never
// happen while a lock is held that the chat-bubble layout also takes — that
// pairing deadlocked in the source fork and the comments there are kept.
public final class AntiDeleteManager {
    public static let shared = AntiDeleteManager()

    // MARK: - Notifications

    public static let settingsChangedNotification = Notification.Name("AYG.antiDeleteSettingsChanged")

    private func notifySettingsChanged() {
        self.syncCaptureFlagToAppGroup()
        NotificationCenter.default.post(name: AntiDeleteManager.settingsChangedNotification, object: nil)
    }

    // MARK: - Settings storage

    private let defaults = AYGSharedDefaults.store

    private let enabledKey = "AYG.antiDelete.enabled"
    private let archiveMediaKey = "AYG.antiDelete.archiveMedia"
    private let keepLocallyWhenDeletingForEveryoneKey = "AYG.antiDelete.keepLocallyWhenDeletingForEveryone"
    private let preserveTTLKey = "AYG.antiDelete.preserveTTL"
    private let deletedMessageTransparencyKey = "AYG.antiDelete.deletedMessageTransparency"
    private let localEditedMessageTransparencyKey = "AYG.antiDelete.localEditedMessageTransparency"
    private let displayEditedMessagesKey = "AYG.antiDelete.displayEditedMessages"
    private let showDeletedInBotsKey = "AYG.antiDelete.showDeletedInBots"
    private let showEditedInBotsKey = "AYG.antiDelete.showEditedInBots"
    private let showDeletedInChannelsKey = "AYG.antiDelete.showDeletedInChannels"
    private let showEditedInChannelsKey = "AYG.antiDelete.showEditedInChannels"
    private let mentionUsernameInDeletedReplyKey = "AYG.antiDelete.mentionUsernameInDeletedReply"
    private let autoClearIntervalKey = "AYG.antiDelete.autoClearInterval"
    private let legacyArchiveBlobKey = "AYG.antiDelete.archive"
    private let deletedIdsKey = "AYG.antiDelete.deletedIds"
    private let exclusionsExcludedPeerIdsKey = "AYG.antiDelete.exclusions.excludedPeerIds"
    private let exclusionsExcludeGroupsKey = "AYG.antiDelete.exclusions.excludeAllGroups"
    private let exclusionsPreserveEditedMessagesKey = "AYG.antiDelete.exclusions.preserveEditedMessages"

    /// Key in the App Group defaults. The main app publishes it; extensions only
    /// read it. See `shouldDeferExtensionCloudDelete`.
    private static let sharedCaptureActiveKey = "AYG.antiDelete.captureActive"

    /// Publish the capture gate under its own key so the Notification Service
    /// Extension — a separate process, which must not re-derive the gate from
    /// the raw settings — can decide whether to defer a hard delete.
    private func syncCaptureFlagToAppGroup() {
        // Only the main app is the source of truth. Extensions run this same code
        // with empty settings and must never overwrite the published flag.
        guard !AYGRuntimeEnvironment.isAppExtensionProcess else {
            return
        }
        AYGRuntimeEnvironment.sharedDefaults?.set(self.defaults.bool(forKey: self.enabledKey), forKey: AntiDeleteManager.sharedCaptureActiveKey)
    }

    /// True only inside an app extension when the main app has signalled that
    /// capture is active. The extension must then NOT hard-delete cloud messages
    /// from the shared postbox: it leaves them for the main app to archive on the
    /// next sync. Worst case the main app never re-receives the update and the
    /// message survives unflagged — strictly better than losing it.
    public var shouldDeferExtensionCloudDelete: Bool {
        guard AYGRuntimeEnvironment.isAppExtensionProcess else {
            return false
        }
        return AYGRuntimeEnvironment.sharedDefaults?.bool(forKey: AntiDeleteManager.sharedCaptureActiveKey) ?? false
    }

    // MARK: - Settings

    /// Master switch — AyuGram's "Save Deleted Messages".
    public var isEnabled: Bool {
        get { return self.defaults.bool(forKey: self.enabledKey) }
        set {
            self.defaults.set(newValue, forKey: self.enabledKey)
            self.notifySettingsChanged()
        }
    }

    /// Capture-side reading of `isEnabled`. Kept as a separate name because the
    /// source fork gated the two differently and every hook site calls this one;
    /// keeping the split makes the hooks diffable against the original.
    public var shouldCapture: Bool {
        return self.defaults.bool(forKey: self.enabledKey)
    }

    /// AyuGram's "Save Attachments": copy the message's already-downloaded media
    /// out of Telegram's cache before the deletion purges it.
    public var archiveMedia: Bool {
        get {
            if self.defaults.object(forKey: self.archiveMediaKey) == nil {
                return true
            }
            return self.defaults.bool(forKey: self.archiveMediaKey)
        }
        set {
            self.defaults.set(newValue, forKey: self.archiveMediaKey)
            self.notifySettingsChanged()
        }
    }

    /// Keep your own messages locally when you delete them for everyone.
    public var keepLocallyWhenDeletingForEveryone: Bool {
        get { return self.defaults.bool(forKey: self.keepLocallyWhenDeletingForEveryoneKey) }
        set {
            self.defaults.set(newValue, forKey: self.keepLocallyWhenDeletingForEveryoneKey)
            self.notifySettingsChanged()
        }
    }

    /// Capture TTL messages (self-destruct media, one-time, secret-chat TTL,
    /// chat-wide auto-delete) just before the autoremove watchdog destroys them.
    public var preserveTTL: Bool {
        get {
            if self.defaults.object(forKey: self.preserveTTLKey) == nil {
                return true
            }
            return self.defaults.bool(forKey: self.preserveTTLKey)
        }
        set {
            self.defaults.set(newValue, forKey: self.preserveTTLKey)
            self.notifySettingsChanged()
        }
    }

    public var shouldPreserveTTL: Bool {
        return self.shouldCapture && self.preserveTTL
    }

    /// AyuGram's "Save Edits History": keep the pre-edit text and show it.
    public var displayEditedMessages: Bool {
        get {
            if self.defaults.object(forKey: self.displayEditedMessagesKey) == nil {
                return true
            }
            return self.defaults.bool(forKey: self.displayEditedMessagesKey)
        }
        set {
            self.defaults.set(newValue, forKey: self.displayEditedMessagesKey)
            self.notifySettingsChanged()
        }
    }

    public var showDeletedInBots: Bool {
        get {
            if self.defaults.object(forKey: self.showDeletedInBotsKey) == nil {
                return true
            }
            return self.defaults.bool(forKey: self.showDeletedInBotsKey)
        }
        set {
            self.defaults.set(newValue, forKey: self.showDeletedInBotsKey)
            self.notifySettingsChanged()
        }
    }

    public var showEditedInBots: Bool {
        get {
            if self.defaults.object(forKey: self.showEditedInBotsKey) == nil {
                return true
            }
            return self.defaults.bool(forKey: self.showEditedInBotsKey)
        }
        set {
            self.defaults.set(newValue, forKey: self.showEditedInBotsKey)
            self.notifySettingsChanged()
        }
    }

    /// AyuGram's single "Save in Bot Dialogs" row drives both halves at once —
    /// `AyuConfig.saveDeletedMessageFor` and `saveEditedMessageFor` both consult
    /// the same `saveForBots` flag.
    public var saveInBotDialogs: Bool {
        get { return self.showDeletedInBots || self.showEditedInBots }
        set {
            self.defaults.set(newValue, forKey: self.showDeletedInBotsKey)
            self.defaults.set(newValue, forKey: self.showEditedInBotsKey)
            self.notifySettingsChanged()
        }
    }

    /// Deleted posts in broadcast channels. No row on AyuGram's Spy screen; kept
    /// as a setting because the hooks below consult it.
    public var showDeletedInChannels: Bool {
        get {
            if self.defaults.object(forKey: self.showDeletedInChannelsKey) == nil {
                return true
            }
            return self.defaults.bool(forKey: self.showDeletedInChannelsKey)
        }
        set {
            self.defaults.set(newValue, forKey: self.showDeletedInChannelsKey)
            self.notifySettingsChanged()
        }
    }

    public var showEditedInChannels: Bool {
        get {
            if self.defaults.object(forKey: self.showEditedInChannelsKey) == nil {
                return true
            }
            return self.defaults.bool(forKey: self.showEditedInChannelsKey)
        }
        set {
            self.defaults.set(newValue, forKey: self.showEditedInChannelsKey)
            self.notifySettingsChanged()
        }
    }

    /// Use @username rather than the display name when quoting a deleted message.
    public var mentionUsernameInDeletedReply: Bool {
        get { return self.defaults.bool(forKey: self.mentionUsernameInDeletedReplyKey) }
        set {
            self.defaults.set(newValue, forKey: self.mentionUsernameInDeletedReplyKey)
            self.notifySettingsChanged()
        }
    }

    /// Hours between automatic archive wipes. 0 = never.
    public var autoClearInterval: Int32 {
        get { return Int32(self.defaults.integer(forKey: self.autoClearIntervalKey)) }
        set {
            self.defaults.set(Int(newValue), forKey: self.autoClearIntervalKey)
            self.notifySettingsChanged()
            self.scheduleAutoClear()
        }
    }

    private var autoClearTimer: DispatchSourceTimer?

    public func scheduleAutoClear() {
        self.autoClearTimer?.cancel()
        self.autoClearTimer = nil
        let interval = self.autoClearInterval
        guard interval > 0 else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + Double(interval) * 3600.0, repeating: Double(interval) * 3600.0)
        timer.setEventHandler { [weak self] in
            self?.clearArchive()
            EditHistoryManager.shared.clearAllHistory()
            LocalEditManager.shared.clearAllEdits()
        }
        timer.resume()
        self.autoClearTimer = timer
    }

    // MARK: - Rendering knobs

    public static let minDeletedMessageTransparency: Double = 0.0
    public static let maxDeletedMessageTransparency: Double = 0.8
    public static let defaultDeletedMessageTransparency: Double = 0.45
    public static let defaultLocalEditedMessageTransparency: Double = 0.45

    public var deletedMessageTransparency: Double {
        get {
            let value = self.defaults.object(forKey: self.deletedMessageTransparencyKey) as? NSNumber
            let resolved = value?.doubleValue ?? AntiDeleteManager.defaultDeletedMessageTransparency
            return max(AntiDeleteManager.minDeletedMessageTransparency, min(AntiDeleteManager.maxDeletedMessageTransparency, resolved))
        }
        set {
            let clamped = max(AntiDeleteManager.minDeletedMessageTransparency, min(AntiDeleteManager.maxDeletedMessageTransparency, newValue))
            self.defaults.set(clamped, forKey: self.deletedMessageTransparencyKey)
            self.notifySettingsChanged()
        }
    }

    public var deletedMessageDisplayAlpha: Double {
        return 1.0 - self.deletedMessageTransparency
    }

    public var localEditedMessageTransparency: Double {
        get {
            let value = self.defaults.object(forKey: self.localEditedMessageTransparencyKey) as? NSNumber
            let resolved = value?.doubleValue ?? AntiDeleteManager.defaultLocalEditedMessageTransparency
            return max(AntiDeleteManager.minDeletedMessageTransparency, min(AntiDeleteManager.maxDeletedMessageTransparency, resolved))
        }
        set {
            let clamped = max(AntiDeleteManager.minDeletedMessageTransparency, min(AntiDeleteManager.maxDeletedMessageTransparency, newValue))
            self.defaults.set(clamped, forKey: self.localEditedMessageTransparencyKey)
            self.notifySettingsChanged()
        }
    }

    public var localEditedMessageDisplayAlpha: Double {
        return 1.0 - self.localEditedMessageTransparency
    }

    // MARK: - Exclusions
    //
    // No master switch: a non-empty exclusion is itself the switch. The source
    // fork also had folder-scoped exclusions, which needed a chat-folder picker
    // that is not part of this port — those are deliberately not carried over.

    public var excludedPeerIds: Set<Int64> {
        get {
            guard let array = self.defaults.array(forKey: self.exclusionsExcludedPeerIdsKey) as? [NSNumber] else {
                return []
            }
            return Set(array.map { $0.int64Value })
        }
        set {
            self.defaults.set(Array(newValue).map { NSNumber(value: $0) }, forKey: self.exclusionsExcludedPeerIdsKey)
            self.notifySettingsChanged()
        }
    }

    /// Skip groups. Basic groups are caught by namespace here; supergroups are
    /// caught by the `chatPeer:` overload, where the peer object is available.
    public var excludeAllGroups: Bool {
        get { return self.defaults.bool(forKey: self.exclusionsExcludeGroupsKey) }
        set {
            self.defaults.set(newValue, forKey: self.exclusionsExcludeGroupsKey)
            self.notifySettingsChanged()
        }
    }

    /// Keep edit history even in excluded chats. Default true, so an exclusion
    /// only affects deleted messages unless the user says otherwise.
    public var preserveEditedMessagesInExclusions: Bool {
        get {
            if self.defaults.object(forKey: self.exclusionsPreserveEditedMessagesKey) == nil {
                return true
            }
            return self.defaults.bool(forKey: self.exclusionsPreserveEditedMessagesKey)
        }
        set {
            self.defaults.set(newValue, forKey: self.exclusionsPreserveEditedMessagesKey)
            self.notifySettingsChanged()
        }
    }

    public func addExcludedPeer(_ peerId: Int64) {
        var ids = self.excludedPeerIds
        ids.insert(peerId)
        self.excludedPeerIds = ids
    }

    public func removeExcludedPeer(_ peerId: Int64) {
        var ids = self.excludedPeerIds
        ids.remove(peerId)
        self.excludedPeerIds = ids
    }

    public func isPeerExcluded(_ peerId: Int64) -> Bool {
        let equivalents = self.equivalentPeerIds(for: peerId)
        if !equivalents.isDisjoint(with: self.excludedPeerIds) {
            return true
        }
        if self.excludeAllGroups && PeerId(peerId).namespace == Namespaces.Peer.CloudGroup {
            return true
        }
        return false
    }

    /// The author check matters: when an excluded contact deletes a message in a
    /// *group* you share, the chat id is the group's (not excluded) but the
    /// author is — and the user expects that deletion skipped too.
    public func isMessageExcluded(chatPeerId: Int64, authorId: Int64?) -> Bool {
        if self.isPeerExcluded(chatPeerId) {
            return true
        }
        if let authorId = authorId, self.isPeerExcluded(authorId) {
            return true
        }
        return false
    }

    public func isMessageExcluded(chatPeerId: Int64, chatPeer: Peer?, authorId: Int64?) -> Bool {
        if self.isMessageExcluded(chatPeerId: chatPeerId, authorId: authorId) {
            return true
        }
        if self.excludeAllGroups, let channel = chatPeer as? TelegramChannel, case .group = channel.info {
            return true
        }
        return false
    }

    public func shouldPreserveEditedContentInChat(chatPeerId: Int64, chatPeer: Peer?, authorId: Int64?) -> Bool {
        if self.isMessageExcluded(chatPeerId: chatPeerId, chatPeer: chatPeer, authorId: authorId) {
            return self.preserveEditedMessagesInExclusions
        }
        return true
    }

    public func shouldPreserveEditedContentInChat(chatPeerId: Int64, authorId: Int64?) -> Bool {
        if self.isMessageExcluded(chatPeerId: chatPeerId, authorId: authorId) {
            return self.preserveEditedMessagesInExclusions
        }
        return true
    }

    /// A peer id reaches this class both raw (`PeerId.Id`) and encoded
    /// (`PeerId.toInt64()`), depending on the call site. Compare against every
    /// spelling rather than trusting the caller.
    private func equivalentPeerIds(for peerId: Int64) -> Set<Int64> {
        let decodedPeerId = PeerId(peerId)
        let rawIds = Set([peerId, decodedPeerId.id._internalGetInt64Value()])
        var result: Set<Int64> = rawIds
        let namespaces: [PeerId.Namespace] = [
            Namespaces.Peer.CloudUser,
            Namespaces.Peer.CloudGroup,
            Namespaces.Peer.CloudChannel
        ]
        for rawId in rawIds {
            for namespace in namespaces {
                result.insert(PeerId(namespace: namespace, id: PeerId.Id._internalFromInt64Value(rawId)).toInt64())
            }
        }
        return result
    }

    // MARK: - Deleted message ids

    private var deletedMessageIds: Set<String> = []
    private let deletedIdsLock = NSLock()

    public func markAsDeleted(peerId: Int64, messageId: Int32) {
        self.deletedIdsLock.lock()
        self.deletedMessageIds.insert("\(peerId)_\(messageId)")
        self.deletedIdsLock.unlock()
        self.saveDeletedIds()
    }

    /// Deliberately ungated by `isEnabled`: this is a lookup in the local record,
    /// and it has to keep answering "yes" after the user switches the feature
    /// off, or an already-kept message would be hard-deleted by the next pass.
    public func isMessageDeleted(peerId: Int64, messageId: Int32) -> Bool {
        let key = "\(peerId)_\(messageId)"
        self.deletedIdsLock.lock()
        defer { self.deletedIdsLock.unlock() }
        return self.deletedMessageIds.contains(key)
    }

    /// Whether anything at all is being protected. Lets the hot delete path skip
    /// its per-message postbox lookups entirely on a fresh install or after a
    /// clear.
    public var hasAnyKeptMessages: Bool {
        self.deletedIdsLock.lock()
        defer { self.deletedIdsLock.unlock() }
        return !self.deletedMessageIds.isEmpty
    }

    /// False when anti-delete has nothing to do — no capture, nothing already
    /// kept, no extension deferral. The update-replay hooks check this so a user
    /// with the feature off pays nothing beyond one boolean.
    public var isDeletionInterceptionActive: Bool {
        return self.shouldCapture
            || self.keepLocallyWhenDeletingForEveryone
            || self.shouldDeferExtensionCloudDelete
            || self.hasAnyKeptMessages
    }

    /// Stop protecting one message. Used when the user themselves deletes a kept
    /// bubble — without this the guard in `_internal_deleteMessages` would refuse
    /// the deletion and the message could never be removed from the chat again.
    /// The archive entry is left alone: it records that the *other* side deleted
    /// the message, which is still true.
    public func forgetKeptMessage(peerId: Int64, messageId: Int32) {
        let key = "\(peerId)_\(messageId)"
        self.deletedIdsLock.lock()
        let removed = self.deletedMessageIds.remove(key) != nil
        self.deletedIdsLock.unlock()
        if removed {
            self.saveDeletedIds()
        }
    }

    /// Coalesced, like `saveArchive`. A "delete for everyone" of a hundred
    /// messages must not write the whole id list a hundred times.
    private func saveDeletedIds() {
        self.deletedIdsLock.lock()
        if self.deletedIdsWriteScheduled {
            self.deletedIdsLock.unlock()
            return
        }
        self.deletedIdsWriteScheduled = true
        self.deletedIdsLock.unlock()

        self.persistQueue.asyncAfter(deadline: .now() + AntiDeleteManager.persistDebounce) { [weak self] in
            self?.flushDeletedIds()
        }
    }

    private func flushDeletedIds() {
        self.deletedIdsLock.lock()
        self.deletedIdsWriteScheduled = false
        let ids = Array(self.deletedMessageIds)
        self.deletedIdsLock.unlock()
        self.defaults.set(ids, forKey: self.deletedIdsKey)
    }

    private func loadDeletedIds() {
        if let ids = self.defaults.stringArray(forKey: self.deletedIdsKey) {
            self.deletedIdsLock.lock()
            self.deletedMessageIds = Set(ids)
            self.deletedIdsLock.unlock()
        }
    }

    // MARK: - Archive

    public struct ArchivedMessage: Codable, Equatable {
        public let globalId: Int32
        public let peerId: Int64
        public let messageId: Int32
        public let timestamp: Int32
        public let deletedAt: Int32
        public let authorId: Int64?
        public let authorName: String?
        public let authorUsername: String?
        public let text: String
        public let forwardAuthorId: Int64?
        public let mediaDescription: String?
        /// Forum topic id. Without it, re-opening the chat lands on the topic
        /// list instead of the message. Absent in older archives.
        public let threadId: Int64?
        /// File name inside the attachments folder, when the media was copied
        /// out before the deletion purged Telegram's cache.
        public let archivedMediaFileName: String?

        public init(
            globalId: Int32,
            peerId: Int64,
            messageId: Int32,
            timestamp: Int32,
            deletedAt: Int32,
            authorId: Int64?,
            authorName: String? = nil,
            authorUsername: String? = nil,
            text: String,
            forwardAuthorId: Int64?,
            mediaDescription: String?,
            threadId: Int64? = nil,
            archivedMediaFileName: String? = nil
        ) {
            self.globalId = globalId
            self.peerId = peerId
            self.messageId = messageId
            self.timestamp = timestamp
            self.deletedAt = deletedAt
            self.authorId = authorId
            self.authorName = authorName
            self.authorUsername = authorUsername
            self.text = text
            self.forwardAuthorId = forwardAuthorId
            self.mediaDescription = mediaDescription
            self.threadId = threadId
            self.archivedMediaFileName = archivedMediaFileName
        }

        private enum CodingKeys: String, CodingKey {
            case globalId, peerId, messageId, timestamp, deletedAt
            case authorId, authorName, authorUsername, text, forwardAuthorId, mediaDescription, threadId
            case archivedMediaFileName
        }

        /// Hand-written so an archive written by an older build — one without
        /// `threadId` or `archivedMediaFileName` — still decodes.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.globalId = try container.decode(Int32.self, forKey: .globalId)
            self.peerId = try container.decode(Int64.self, forKey: .peerId)
            self.messageId = try container.decode(Int32.self, forKey: .messageId)
            self.timestamp = try container.decode(Int32.self, forKey: .timestamp)
            self.deletedAt = try container.decode(Int32.self, forKey: .deletedAt)
            self.authorId = try container.decodeIfPresent(Int64.self, forKey: .authorId)
            self.authorName = try container.decodeIfPresent(String.self, forKey: .authorName)
            self.authorUsername = try container.decodeIfPresent(String.self, forKey: .authorUsername)
            self.text = try container.decode(String.self, forKey: .text)
            self.forwardAuthorId = try container.decodeIfPresent(Int64.self, forKey: .forwardAuthorId)
            self.mediaDescription = try container.decodeIfPresent(String.self, forKey: .mediaDescription)
            self.threadId = try container.decodeIfPresent(Int64.self, forKey: .threadId)
            self.archivedMediaFileName = try container.decodeIfPresent(String.self, forKey: .archivedMediaFileName)
        }
    }

    private var archivedMessages: [ArchivedMessage] = []
    private let archiveLock = NSLock()
    /// O(1) dedup index, rebuilt on every bulk mutation and extended on archive.
    /// A `contains(where:)` scan per captured message turned a "delete for
    /// everyone" of N messages into O(n²) work on the postbox thread.
    private var archivedKeys: Set<String> = []
    /// Disk writes are debounced onto this queue; see `saveArchive`.
    private let persistQueue = DispatchQueue(label: "org.ayugram.AntiDeleteManager.persist", qos: .utility)
    private static let persistDebounce: Double = 1.0
    /// Guarded by `archiveLock`.
    private var archiveWriteScheduled = false
    /// Guarded by `deletedIdsLock`.
    private var deletedIdsWriteScheduled = false

    private static func archiveKey(peerId: Int64, messageId: Int32) -> String {
        return "\(peerId)_\(messageId)"
    }

    /// Must be called while holding `archiveLock`.
    private func rebuildArchivedKeysLocked() {
        self.archivedKeys = Set(self.archivedMessages.map { AntiDeleteManager.archiveKey(peerId: $0.peerId, messageId: $0.messageId) })
    }

    private init() {
        if self.defaults.object(forKey: self.enabledKey) == nil {
            self.defaults.set(true, forKey: self.enabledKey)
        }
        self.loadArchive()
        self.loadDeletedIds()
        self.syncCaptureFlagToAppGroup()
        // Pull in anything an extension captured while the main app was closed,
        // and again on every foreground — an extension also runs while the app is
        // merely backgrounded, which `init` alone would not catch.
        if !AYGRuntimeEnvironment.isAppExtensionProcess {
            NotificationCenter.default.addObserver(forName: aygApplicationDidBecomeActiveNotificationName, object: nil, queue: nil) { [weak self] _ in
                self?.drainSharedJournalIfNeeded()
            }
            NotificationCenter.default.addObserver(forName: aygApplicationWillResignActiveNotificationName, object: nil, queue: nil) { [weak self] _ in
                self?.flushPendingWrites()
            }
        }
        self.drainSharedJournalIfNeeded()
    }

    // MARK: - Archive operations

    public func archiveMessage(
        globalId: Int32,
        peerId: Int64,
        messageId: Int32,
        timestamp: Int32,
        authorId: Int64?,
        authorName: String? = nil,
        authorUsername: String? = nil,
        text: String,
        forwardAuthorId: Int64? = nil,
        mediaDescription: String? = nil,
        threadId: Int64? = nil,
        archivedMediaFileName: String? = nil,
        chatPeer: Peer? = nil
    ) {
        // In the main app this is the live gate. Inside an extension the local
        // settings are empty, so we trust the flag the main app published and
        // journal into the App Group — the extension cannot write the archive.
        let inExtension = AYGRuntimeEnvironment.isAppExtensionProcess
        let capturing = inExtension ? self.shouldDeferExtensionCloudDelete : self.shouldCapture
        guard capturing else {
            return
        }
        guard !self.isMessageExcluded(chatPeerId: peerId, chatPeer: chatPeer, authorId: authorId) else {
            return
        }

        let archived = ArchivedMessage(
            globalId: globalId,
            peerId: peerId,
            messageId: messageId,
            timestamp: timestamp,
            deletedAt: Int32(Date().timeIntervalSince1970),
            authorId: authorId,
            authorName: authorName,
            authorUsername: authorUsername,
            text: text,
            forwardAuthorId: forwardAuthorId,
            mediaDescription: mediaDescription,
            threadId: threadId,
            archivedMediaFileName: archivedMediaFileName
        )

        if inExtension {
            self.appendToSharedJournal(archived)
            return
        }

        self.archiveLock.lock()
        defer { self.archiveLock.unlock() }

        // Dedup on (peerId, messageId), NOT globalId: for TTL/secret/local
        // captures globalId falls back to the local id, which is only unique per
        // peer, so a globalId-only check could skip a genuinely new message in
        // another chat that happens to share the number.
        let key = AntiDeleteManager.archiveKey(peerId: peerId, messageId: messageId)
        if self.archivedKeys.insert(key).inserted {
            self.archivedMessages.append(archived)
            self.saveArchive()
        }
    }

    // MARK: - Shared App Group journal (extension → main app)

    private var sharedJournalDirURL: URL? {
        guard let container = AYGRuntimeEnvironment.appGroupContainerURL else {
            return nil
        }
        return container.appendingPathComponent("ayugram_pending_deleted", isDirectory: true)
    }

    /// Extension side. Deterministic per-message file names make a re-processed
    /// update idempotent and sidestep cross-process append tearing: each file is
    /// written once, by one process.
    private func appendToSharedJournal(_ message: ArchivedMessage) {
        guard let dir = self.sharedJournalDirURL else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(message.peerId)_\(message.messageId).json")
            let data = try JSONEncoder().encode(message)
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.shared.log("AYGAntiDelete", "journal append failed: \(error)")
        }
    }

    /// Main-app side. Safe to call repeatedly; no-op in extensions.
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

        // Decode off-lock, and leave undecodable files in place — a schema change
        // must not silently destroy captured data. File I/O stays outside
        // `archiveLock` so a large drain cannot stall archive readers.
        var decoded: [(message: ArchivedMessage, url: URL)] = []
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let message = try? JSONDecoder().decode(ArchivedMessage.self, from: data) {
                decoded.append((message, url))
            }
        }
        guard !decoded.isEmpty else {
            return
        }

        var mergedMessages: [ArchivedMessage] = []
        self.archiveLock.lock()
        for (message, _) in decoded {
            let key = AntiDeleteManager.archiveKey(peerId: message.peerId, messageId: message.messageId)
            if self.archivedKeys.insert(key).inserted {
                self.archivedMessages.append(message)
                mergedMessages.append(message)
            }
        }
        if !mergedMessages.isEmpty {
            self.saveArchive()
        }
        self.archiveLock.unlock()

        // Drained files are removed whether or not they merged: a dedup hit means
        // the data is already in the archive, and keeping the file would redo
        // this work on every launch.
        for (_, url) in decoded {
            try? fileManager.removeItem(at: url)
        }

        guard !mergedMessages.isEmpty else {
            return
        }
        self.deletedIdsLock.lock()
        for message in mergedMessages {
            self.deletedMessageIds.insert("\(message.peerId)_\(message.messageId)")
        }
        self.deletedIdsLock.unlock()
        self.saveDeletedIds()
        // Direct post, not `notifySettingsChanged` — draining must not re-publish
        // the capture flag, only refresh the archive list and the chat bubbles.
        NotificationCenter.default.post(name: AntiDeleteManager.settingsChangedNotification, object: nil)
    }

    // MARK: - Archive reads

    public func getAllArchivedMessages() -> [ArchivedMessage] {
        self.archiveLock.lock()
        defer { self.archiveLock.unlock() }
        return self.archivedMessages.sorted { $0.deletedAt > $1.deletedAt }
    }

    public func getArchivedMessages(forPeerId peerId: Int64) -> [ArchivedMessage] {
        self.archiveLock.lock()
        defer { self.archiveLock.unlock() }
        return self.archivedMessages
            .filter { $0.peerId == peerId }
            .sorted { $0.deletedAt > $1.deletedAt }
    }

    public func getArchivedMessage(peerId: Int64, messageId: Int32) -> ArchivedMessage? {
        self.archiveLock.lock()
        defer { self.archiveLock.unlock() }
        return self.archivedMessages.first(where: { $0.peerId == peerId && $0.messageId == messageId })
    }

    public func isArchivedMessage(peerId: Int64, messageId: Int32) -> Bool {
        self.archiveLock.lock()
        defer { self.archiveLock.unlock() }
        return self.archivedKeys.contains(AntiDeleteManager.archiveKey(peerId: peerId, messageId: messageId))
    }

    /// Ungated safety net so an already-kept message cannot be hidden by a
    /// secondary delete event.
    public func isArchivedGlobalId(_ globalId: Int32) -> Bool {
        self.archiveLock.lock()
        defer { self.archiveLock.unlock() }
        return self.archivedMessages.contains(where: { $0.globalId == globalId })
    }

    public var archivedCount: Int {
        self.archiveLock.lock()
        defer { self.archiveLock.unlock() }
        return self.archivedMessages.count
    }

    public func hasArchivedMessages(forPeerId peerId: Int64) -> Bool {
        self.archiveLock.lock()
        defer { self.archiveLock.unlock() }
        return self.archivedMessages.contains(where: { $0.peerId == peerId })
    }

    /// Indices of a peer's kept messages, oldest first — the shape a chat search
    /// result wants, so "show deleted" can step through them.
    public func archivedMessageIndices(forPeerId peerId: Int64) -> [MessageIndex] {
        self.archiveLock.lock()
        let snapshot = self.archivedMessages.filter { $0.peerId == peerId }
        self.archiveLock.unlock()

        return snapshot
            .sorted { $0.timestamp < $1.timestamp }
            .map { entry in
                return MessageIndex(
                    id: MessageId(peerId: PeerId(entry.peerId), namespace: Namespaces.Message.Cloud, id: entry.messageId),
                    timestamp: entry.timestamp
                )
            }
    }

    // MARK: - Archive mutation

    public func clearArchive() {
        self.archiveLock.lock()
        self.archivedMessages.removeAll()
        self.archivedKeys.removeAll()
        self.saveArchive()
        self.archiveLock.unlock()

        self.deletedIdsLock.lock()
        self.deletedMessageIds.removeAll()
        self.deletedIdsLock.unlock()
        self.saveDeletedIds()

        NotificationCenter.default.post(name: AntiDeleteManager.settingsChangedNotification, object: nil)
    }

    public func removeFromArchive(globalId: Int32) {
        self.archiveLock.lock()
        defer { self.archiveLock.unlock() }
        self.archivedMessages.removeAll { $0.globalId == globalId }
        self.rebuildArchivedKeysLocked()
        self.saveArchive()
    }

    // MARK: - Export / import

    /// Pull the JSON payload out of an HTML export, or pass the bytes through
    /// unchanged when they already look like raw JSON. Shared with
    /// `EditHistoryManager` — same wire format, different script id.
    public static func extractJSONPayload(from data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else {
            return data
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            return data
        }
        let pattern = #"<script[^>]*type=\"application/json\"[^>]*>([\s\S]*?)</script>"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           match.numberOfRanges >= 2,
           let range = Range(match.range(at: 1), in: text) {
            let payload = String(text[range]).replacingOccurrences(of: "<\\/", with: "</")
            return Data(payload.utf8)
        }
        return data
    }

    static func htmlEscape(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// An HTML file that is both a readable table and its own re-import source:
    /// the exact JSON sits in a `<script type="application/json">` block. Raw
    /// JSON would import just as well but shows the user nothing.
    public func exportArchiveData() -> Data? {
        self.archiveLock.lock()
        let snapshot = self.archivedMessages
        self.archiveLock.unlock()

        guard let json = try? JSONEncoder().encode(snapshot), let jsonString = String(data: json, encoding: .utf8) else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        var rows = ""
        for message in snapshot.sorted(by: { $0.deletedAt > $1.deletedAt }) {
            let date = Date(timeIntervalSince1970: TimeInterval(message.deletedAt))
            let text = AntiDeleteManager.htmlEscape(message.text.isEmpty ? (message.mediaDescription ?? "—") : message.text)
            let author = AntiDeleteManager.htmlEscape(message.authorName ?? "—")
            rows += "<tr><td>\(formatter.string(from: date))</td><td>\(message.peerId)</td><td>\(message.messageId)</td><td>\(author)</td><td>\(text)</td></tr>\n"
        }
        // `</script>` cannot appear inside JSONEncoder output (it escapes `/`),
        // but split-encode anyway.
        let safePayload = jsonString.replacingOccurrences(of: "</", with: "<\\/")
        let html = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <title>AyuGram — deleted messages</title>
        <style>
        body{font:14px/1.4 -apple-system,BlinkMacSystemFont,Helvetica,Arial,sans-serif;padding:20px;background:#fafafa;color:#222}
        h1{font-size:18px;margin-bottom:4px}
        .meta{color:#666;margin-bottom:16px}
        table{border-collapse:collapse;width:100%;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.06)}
        th,td{padding:8px 10px;border-bottom:1px solid #eee;text-align:left;vertical-align:top}
        th{background:#f3f3f3;font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.04em}
        td{font-size:13px}
        </style></head><body>
        <h1>Deleted messages</h1>
        <div class="meta">Exported by AyuGram. This file is also the import source — do not remove the <code>&lt;script id="ayugram-archive"&gt;</code> block.</div>
        <table><thead><tr><th>Deleted</th><th>Peer</th><th>Message</th><th>Author</th><th>Text</th></tr></thead>
        <tbody>
        \(rows)</tbody></table>
        <script id="ayugram-archive" type="application/json">\(safePayload)</script>
        </body></html>
        """
        return html.data(using: .utf8)
    }

    /// Accepts the HTML export above or raw JSON of the same shape.
    /// `merge: false` replaces the archive outright.
    @discardableResult
    public func importArchiveData(_ data: Data, merge: Bool = true) -> (added: Int, total: Int) {
        let payload = AntiDeleteManager.extractJSONPayload(from: data)
        guard let incoming = try? JSONDecoder().decode([ArchivedMessage].self, from: payload) else {
            return (0, self.archivedCount)
        }

        var added = 0
        self.archiveLock.lock()
        self.deletedIdsLock.lock()
        if merge {
            // Dedup on the same (peerId, messageId) identity `archivedKeys` uses,
            // so the array and the index can never disagree on cardinality.
            for message in incoming {
                let key = AntiDeleteManager.archiveKey(peerId: message.peerId, messageId: message.messageId)
                if self.archivedKeys.insert(key).inserted {
                    self.archivedMessages.append(message)
                    self.deletedMessageIds.insert(key)
                    added += 1
                }
            }
        } else {
            self.archivedMessages = incoming
            self.rebuildArchivedKeysLocked()
            self.deletedMessageIds = Set(incoming.map { AntiDeleteManager.archiveKey(peerId: $0.peerId, messageId: $0.messageId) })
            added = incoming.count
        }
        let total = self.archivedMessages.count
        self.deletedIdsLock.unlock()
        self.saveArchive()
        self.archiveLock.unlock()

        self.saveDeletedIds()
        NotificationCenter.default.post(name: AntiDeleteManager.settingsChangedNotification, object: nil)
        return (added, total)
    }

    // MARK: - Persistence

    // File-backed, not UserDefaults-backed: the archive has no size ceiling and
    // UserDefaults does. The old UserDefaults blob is still read once, to migrate.
    private static func documentsURL(_ name: String) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(name)
    }

    /// Bytes the "AyuGram Messages Database" occupies — what the Clear sheet
    /// labels that row with. Edit history lives in `UserDefaults` rather than a
    /// file of its own and is therefore not counted here.
    public static func databaseStorageSize() -> Int64 {
        let names = [
            "ayugram_deleted_archive.json",
            "ayugram_deleted_archive.backup.json",
            "ayugram_local_edits.json",
            "ayugram_spy_data.json"
        ]
        var total: Int64 = 0
        for name in names {
            let url = AntiDeleteManager.documentsURL(name)
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private var archiveFileURL: URL {
        return AntiDeleteManager.documentsURL("ayugram_deleted_archive.json")
    }

    private var archiveBackupURL: URL {
        return AntiDeleteManager.documentsURL("ayugram_deleted_archive.backup.json")
    }

    /// Schedule a write. Must be called while holding `archiveLock`.
    ///
    /// Coalesced deliberately. Every capture rewrites the entire archive — encode
    /// N entries, copy the backup, write atomically — and captures arrive in
    /// bursts on the postbox queue, so writing per message is quadratic and can
    /// stall a "delete for everyone" of a large selection outright. The window
    /// this opens is small and not dangerous: the durable half of a capture is
    /// the `DeletedMessageAttribute`, written inside the postbox transaction
    /// itself, so a crash inside the debounce loses at most the archived *text*
    /// of the last second — never the message.
    private func saveArchive() {
        if self.archiveWriteScheduled {
            return
        }
        self.archiveWriteScheduled = true
        self.persistQueue.asyncAfter(deadline: .now() + AntiDeleteManager.persistDebounce) { [weak self] in
            self?.flushArchive()
        }
    }

    private func flushArchive() {
        self.archiveLock.lock()
        self.archiveWriteScheduled = false
        let snapshot = self.archivedMessages
        self.archiveLock.unlock()

        do {
            let data = try JSONEncoder().encode(snapshot)
            let url = self.archiveFileURL
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: self.archiveBackupURL)
                try? FileManager.default.copyItem(at: url, to: self.archiveBackupURL)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.shared.log("AYGAntiDelete", "failed to save archive: \(error)")
        }
    }

    /// Write anything still pending, now. Bound to the app going inactive.
    public func flushPendingWrites() {
        self.archiveLock.lock()
        let hasArchiveWrite = self.archiveWriteScheduled
        self.archiveLock.unlock()
        if hasArchiveWrite {
            self.flushArchive()
        }
        self.deletedIdsLock.lock()
        let hasIdsWrite = self.deletedIdsWriteScheduled
        self.deletedIdsLock.unlock()
        if hasIdsWrite {
            self.flushDeletedIds()
        }
    }

    private func loadArchive() {
        defer { self.rebuildArchivedKeysLocked() }

        if let data = try? Data(contentsOf: self.archiveFileURL),
           let decoded = try? JSONDecoder().decode([ArchivedMessage].self, from: data) {
            self.archivedMessages = decoded
            return
        }
        if let data = try? Data(contentsOf: self.archiveBackupURL),
           let decoded = try? JSONDecoder().decode([ArchivedMessage].self, from: data) {
            self.archivedMessages = decoded
            self.saveArchive()
            return
        }
        if let data = self.defaults.data(forKey: self.legacyArchiveBlobKey),
           let decoded = try? JSONDecoder().decode([ArchivedMessage].self, from: data) {
            self.archivedMessages = decoded
            self.saveArchive()
            self.defaults.removeObject(forKey: self.legacyArchiveBlobKey)
            return
        }
        self.archivedMessages = []
    }
}
