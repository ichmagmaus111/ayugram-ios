import Foundation
import Postbox

// AYG: storage for the Customization screen, and the questions the rendering sites ask
// it.
//
// Ported from AyuGram for Android's `AyuConfig` — which is a `SharedPreferences` bag,
// one key per setting, not a serialised record. Kept that shape here rather than the
// single-JSON-blob shape `AYGGhostModeManager` uses, because these settings are read on
// the chat-bubble layout path: `deletedMark` is asked for once per visible message, and
// a JSON decode there would be absurd. Each value is cached behind the lock and only
// re-read from disk when it changes.
//
// Everything lives in `AYGSharedDefaults.store` — the App Group suite — under the
// `AYG.customization.` prefix, so the Notification Service and Share extensions see the
// same values the app does. Never `UserDefaults.standard`.
public final class AYGCustomizationManager {

    // MARK: - Singleton

    public static let shared = AYGCustomizationManager()

    // MARK: - UserDefaults keys

    private enum Keys {
        static let semiTransparentDeletedMessages = "AYG.customization.semiTransparentDeletedMessages"
        static let deletedMark = "AYG.customization.deletedMark"
        static let deletedMarkColor = "AYG.customization.deletedMarkColor"
        static let localPremium = "AYG.customization.localPremium"
        static let disableAds = "AYG.customization.disableAds"
        static let displayGhostStatus = "AYG.customization.displayGhostStatus"
        static let sawLocalPremiumAlert = "AYG.customization.sawLocalPremiumAlert"
    }

    // MARK: - Storage

    private let defaults = AYGSharedDefaults.store
    /// `NSRecursiveLock` for the same reason `AYGGhostModeManager` uses one: a setter
    /// posts the change notification, an observer can read another setting straight
    /// back, and a plain lock (or a `DispatchQueue.sync`) deadlocks on that re-entry.
    private let lock = NSRecursiveLock()

    private var cached: AYGCustomizationSettings?

    private init() {}

    // MARK: - Notifications

    /// Posted after any setting changes. The chat rendering path listens for this and
    /// re-lays out visible messages; the settings screen listens so a change made on
    /// another screen (or by an extension) shows up.
    public static let settingsChangedNotification = Notification.Name("AYGCustomizationSettingsChanged")

    private func notifySettingsChanged() {
        NotificationCenter.default.post(name: AYGCustomizationManager.settingsChangedNotification, object: nil)
    }

    // MARK: - The whole record

    /// Every setting at once. The settings screen renders from this; the rendering path
    /// uses the narrow accessors below.
    public var settings: AYGCustomizationSettings {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.loadLocked()
    }

    private func loadLocked() -> AYGCustomizationSettings {
        if let cached = self.cached {
            return cached
        }
        let fallback = AYGCustomizationSettings.default
        var result = fallback
        if let value = self.defaults.object(forKey: Keys.semiTransparentDeletedMessages) as? NSNumber {
            result.semiTransparentDeletedMessages = value.boolValue
        }
        if let value = self.defaults.object(forKey: Keys.deletedMark) as? NSNumber,
           let mark = AYGDeletedMark(rawValue: value.intValue) {
            result.deletedMark = mark
        }
        if let value = self.defaults.object(forKey: Keys.deletedMarkColor) as? NSNumber {
            // A stored index can outlive the palette it was written against — clamp
            // rather than trusting it, or the picker would index out of bounds.
            result.deletedMarkColor = max(0, min(AYGCustomizationSettings.deletedMarkPaletteCount - 1, value.intValue))
        }
        if let value = self.defaults.object(forKey: Keys.localPremium) as? NSNumber {
            result.localPremium = value.boolValue
        }
        if let value = self.defaults.object(forKey: Keys.disableAds) as? NSNumber {
            result.disableAds = value.boolValue
        }
        if let value = self.defaults.object(forKey: Keys.displayGhostStatus) as? NSNumber {
            result.displayGhostStatus = value.boolValue
        }
        if let value = self.defaults.object(forKey: Keys.sawLocalPremiumAlert) as? NSNumber {
            result.sawLocalPremiumAlert = value.boolValue
        }
        self.cached = result
        return result
    }

    /// Read-modify-write the whole record under one lock, writing and notifying only if
    /// something actually changed. The individual setters below all go through this, and
    /// so does the settings screen — which changes two fields at once when switching
    /// local premium on for the first time.
    public func update(_ f: (inout AYGCustomizationSettings) -> Void) {
        self.lock.lock()
        var settings = self.loadLocked()
        let previous = settings
        f(&settings)
        guard settings != previous else {
            self.lock.unlock()
            return
        }
        self.cached = settings
        self.defaults.set(settings.semiTransparentDeletedMessages, forKey: Keys.semiTransparentDeletedMessages)
        self.defaults.set(settings.deletedMark.rawValue, forKey: Keys.deletedMark)
        self.defaults.set(settings.deletedMarkColor, forKey: Keys.deletedMarkColor)
        self.defaults.set(settings.localPremium, forKey: Keys.localPremium)
        self.defaults.set(settings.disableAds, forKey: Keys.disableAds)
        self.defaults.set(settings.displayGhostStatus, forKey: Keys.displayGhostStatus)
        self.defaults.set(settings.sawLocalPremiumAlert, forKey: Keys.sawLocalPremiumAlert)
        self.lock.unlock()

        self.notifySettingsChanged()
    }

    // MARK: - Individual settings

    public var semiTransparentDeletedMessages: Bool {
        get {
            return self.settings.semiTransparentDeletedMessages
        }
        set {
            self.update { $0.semiTransparentDeletedMessages = newValue }
        }
    }

    public var deletedMark: AYGDeletedMark {
        get {
            return self.settings.deletedMark
        }
        set {
            self.update { $0.deletedMark = newValue }
        }
    }

    public var deletedMarkColor: Int {
        get {
            return self.settings.deletedMarkColor
        }
        set {
            self.update { $0.deletedMarkColor = newValue }
        }
    }

    public var localPremium: Bool {
        get {
            return self.settings.localPremium
        }
        set {
            self.update { $0.localPremium = newValue }
        }
    }

    public var disableAds: Bool {
        get {
            return self.settings.disableAds
        }
        set {
            self.update { $0.disableAds = newValue }
        }
    }

    public var displayGhostStatus: Bool {
        get {
            return self.settings.displayGhostStatus
        }
        set {
            self.update { $0.displayGhostStatus = newValue }
        }
    }

    /// AyuGram's `sawLocalPremiumAlert`: the "no increased limits" warning is shown the
    /// first time local premium is switched on and never again.
    public var sawLocalPremiumAlert: Bool {
        get {
            return self.settings.sawLocalPremiumAlert
        }
        set {
            self.update { $0.sawLocalPremiumAlert = newValue }
        }
    }

    // MARK: - Questions the chat rendering path asks

    /// The alpha a message kept by anti-delete is drawn at, or `nil` for "fully opaque",
    /// which is what the switch being off means.
    ///
    /// The *amount* of transparency is the anti-delete screen's slider
    /// (`AntiDeleteManager.deletedMessageTransparency`); this switch only decides
    /// whether it applies at all. AyuGram for Android has a single boolean and a fixed
    /// 0.5f; splitting it that way is this fork's, and keeps the two screens from each
    /// owning half of one number.
    public var deletedMessageAlpha: Double? {
        guard self.semiTransparentDeletedMessages else {
            return nil
        }
        return AntiDeleteManager.shared.deletedMessageDisplayAlpha
    }

    /// Likewise for a message whose text the user rewrote locally.
    public var localEditedMessageAlpha: Double? {
        guard self.semiTransparentDeletedMessages else {
            return nil
        }
        return AntiDeleteManager.shared.localEditedMessageDisplayAlpha
    }

    /// The explicit mark colour as 0xRRGGBB, or `nil` for "the theme's own in-bubble
    /// timestamp colour" — index 0 of the picker.
    public var deletedMarkColorValue: UInt32? {
        return AYGCustomizationSettings.deletedMarkColorValue(self.deletedMarkColor)
    }

    /// The alpha one message's bubble should be drawn at.
    ///
    /// `ChatMessageCell.setAlpha` in the APK clamps a kept message to a flat `0.7f`
    /// whenever `semiTransparentDeletedMessages` is on. Here the *amount* comes from the
    /// anti-delete screen's two sliders instead, so a user who wants the AyuGram look
    /// leaves them at the default and a user who wants more or less has a dial. This
    /// switch is only the on/off.
    ///
    /// Called once per visible message per layout pass, off the main thread — everything
    /// it touches is a cached value, a lock plus a `Set` lookup, or an attribute scan.
    public func displayAlpha(for message: Message) -> Double {
        guard self.semiTransparentDeletedMessages else {
            return 1.0
        }
        if message.aygIsDeleted {
            return AntiDeleteManager.shared.deletedMessageDisplayAlpha
        }
        if LocalEditManager.shared.hasLocalEdit(peerId: message.id.peerId.toInt64(), messageId: message.id.id) {
            return AntiDeleteManager.shared.localEditedMessageDisplayAlpha
        }
        return 1.0
    }

    /// Whether the chat list's title should show a ghost where the emoji status goes.
    ///
    /// `DialogsActivity.updateStatus` in the APK: when this row is on *and* Ghost Mode is
    /// active for the account, the 24dp `ayu_ghost` drawable replaces whatever status
    /// would otherwise be drawn next to the title, tinted with the action-bar title
    /// colour and with the particle effect off. Both halves of the condition matter —
    /// the row on its own shows nothing.
    ///
    /// Stored and answered here; nothing draws it yet. The iOS counterpart of that title
    /// view lives in `ChatListUI`, which this port does not own — see the report.
    public func shouldDisplayGhostStatus(forAccount accountPeerId: EnginePeer.Id?) -> Bool {
        guard self.displayGhostStatus else {
            return false
        }
        return AYGGhostModeManager.shared.isGhostModeActive(forAccount: accountPeerId)
    }

    /// The dimmest alpha across a group of messages — an album is one bubble, and
    /// AyuGram dims the whole thing when any part of it was deleted (`z3`, the
    /// "is part of a grouped message" branch in `ChatMessageCell`).
    public func displayAlpha(forGroup messages: [Message]) -> Double {
        var result: Double = 1.0
        for message in messages {
            result = min(result, self.displayAlpha(for: message))
        }
        return result
    }
}
