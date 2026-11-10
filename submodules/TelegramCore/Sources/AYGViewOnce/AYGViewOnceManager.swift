import Foundation

// AYG: storage for "keep view-once media", and the record of which view-once
// messages have already been opened.
//
// Ported from AyuGram for Android, where the whole feature is three hooks driven by
// one flag (`AyuConfig.getSaveDeletedMessages()`):
//
//   MessageObject.needDrawBluredPreview()   the bubble stops drawing the blurred
//                                           "tap to view" placeholder
//   MessagesController.markMessageAsRead2   `createTaskForMid` is skipped, so the
//                                           local destruct task is never scheduled
//   MessagesStorage.markMessagesContentAsRead
//                                           `AyuState.setMessageBurned` records that
//                                           the one view has been used, which is what
//                                           flips `AyuMessageUtils.formatTTL` from the
//                                           "one view" badge to the burnt icon
//
// Two deliberate departures from the APK, both matching precedent already in this
// fork:
//
//   * AyuGram has no row of its own for this — it rides on Spy ▸ "Save Deleted
//     Messages". Here it is its own setting, the same way `AYGCustomizationManager`
//     splits `semiTransparentDeletedMessages` off the anti-delete sliders instead of
//     letting one screen own half of another screen's behaviour. It defaults **on**,
//     so out of the box the two clients behave identically.
//   * The per-chat exclusions are *not* duplicated. AyuGram's
//     `AyuConfig.saveDeletedMessageFor(account, dialogId)` consults the same exclusion
//     list the anti-delete feature uses, so this asks `AntiDeleteManager` rather than
//     keeping a second copy that could drift: a chat the user excluded from being
//     saved is also a chat whose view-once media we do not keep.
//
// Everything lives in `AYGSharedDefaults.store` — the App Group suite — under the
// `AYG.viewOnce.` prefix, so the Notification Service and Share extensions see the
// same values the app does. Never `UserDefaults.standard`.
public final class AYGViewOnceManager {

    // MARK: - Singleton

    public static let shared = AYGViewOnceManager()

    // MARK: - UserDefaults keys

    private enum Keys {
        static let revealed = "AYG.viewOnce.revealed"
    }

    /// How many "already opened" records are kept. AyuGram writes one
    /// `SharedPreferences` boolean per message and never removes it; a bounded
    /// window is the same thing without the unbounded growth, and losing the
    /// oldest records only costs a badge — never the photo.
    private static let revealedLimit = 4096

    // MARK: - Storage

    private let defaults = AYGSharedDefaults.store
    /// `NSRecursiveLock` for the same reason `AYGCustomizationManager` uses one: a
    /// setter posts the change notification, an observer can read the setting straight
    /// back, and a plain lock deadlocks on that re-entry.
    private let lock = NSRecursiveLock()

    /// Mirrors the persisted list. Read once per visible message on the chat layout
    /// path, so it has to be a `Set` lookup and not a defaults round-trip.
    private var cachedRevealed: Set<String>?
    /// Insertion order, so the window can be trimmed oldest-first.
    private var cachedRevealedOrder: [String] = []

    private init() {}

    // MARK: - Notifications

    /// Posted after the setting changes. The chat rendering path listens for this and
    /// re-lays out visible messages.
    public static let settingsChangedNotification = Notification.Name("AYGViewOnceSettingsChanged")

    /// Posted on the main queue the first time a kept one-time message is revealed, so
    /// the UI can raise AyuGram's "this will not burn" notice. `userInfo` carries the
    /// media kind and a `peerId:messageId` key for the once-per-message guard.
    public static let mediaRevealedNotification = Notification.Name("AYGViewOnceMediaRevealed")
    public static let mediaRevealedKindKey = "kind"
    public static let mediaRevealedMessageKey = "message"

    // MARK: - The setting

    /// Keep view-once media viewable instead of letting it burn on the first look.
    ///
    /// Unconditional, which is AyuGram's own behaviour — it has no switch for this.
    /// Kept as a property rather than inlined at the call site so a per-peer exclusion
    /// later lands in one place.
    public var keepMedia: Bool {
        return true
    }

    // MARK: - The "one view has been used" record

    private static func revealedKey(peerId: Int64, messageId: Int32) -> String {
        return "\(peerId):\(messageId)"
    }

    private func loadRevealedLocked() -> Set<String> {
        if let cached = self.cachedRevealed {
            return cached
        }
        let stored = self.defaults.stringArray(forKey: Keys.revealed) ?? []
        self.cachedRevealedOrder = stored
        let value = Set(stored)
        self.cachedRevealed = value
        return value
    }

    /// The user has already opened this view-once message once.
    ///
    /// `AyuState.isMessageBurned`. Purely cosmetic — it decides which badge the bubble
    /// draws, never whether the media is kept.
    public func isRevealed(peerId: Int64, messageId: Int32) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.loadRevealedLocked().contains(AYGViewOnceManager.revealedKey(peerId: peerId, messageId: messageId))
    }

    /// `AyuState.setMessageBurned`. Called from the consume hook, once, at the moment
    /// the view that Telegram would have charged the user for is spent.
    public func markRevealed(peerId: Int64, messageId: Int32) {
        let key = AYGViewOnceManager.revealedKey(peerId: peerId, messageId: messageId)

        self.lock.lock()
        var revealed = self.loadRevealedLocked()
        guard !revealed.contains(key) else {
            self.lock.unlock()
            return
        }
        revealed.insert(key)
        self.cachedRevealedOrder.append(key)
        while self.cachedRevealedOrder.count > AYGViewOnceManager.revealedLimit {
            let dropped = self.cachedRevealedOrder.removeFirst()
            revealed.remove(dropped)
        }
        self.cachedRevealed = revealed
        self.defaults.set(self.cachedRevealedOrder, forKey: Keys.revealed)
        self.lock.unlock()
    }

    /// Forget every "already opened" record. Nothing calls this yet; it exists so the
    /// Spy screen's existing "clear local data" affordances have something to call
    /// when this feature gets its row.
    public func clearRevealed() {
        self.lock.lock()
        self.cachedRevealed = []
        self.cachedRevealedOrder = []
        self.defaults.removeObject(forKey: Keys.revealed)
        self.lock.unlock()
    }
}

/// The four notices AyuGram shows for kept one-time media. Lives here rather than in
/// the UI so the consume path, which has the message, can name the kind without any
/// UI dependency.
public enum AYGViewOnceKind: String {
    case photo
    case video
    case roundVideo
    case voice
}
