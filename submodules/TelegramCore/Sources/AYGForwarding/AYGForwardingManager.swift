import Foundation

// AYG: storage for the restricted-forwarding mechanism, and the one question every
// enforcement site asks it.
//
// Shaped like `AYGCustomizationManager`: one key per setting in
// `AYGSharedDefaults.store` (the App Group suite, so the Share and Notification Service
// extensions see the same value), cached behind an `NSRecursiveLock`, a change
// notification for screens that render off it. Never `UserDefaults.standard`.
//
// `ignoresCopyProtection` is on the chat **layout** path — `Message.isCopyProtected()`
// is asked once per visible message per pass — so it must stay a cached read behind a
// lock and never touch disk.
public final class AYGForwardingManager {

    // MARK: - Singleton

    public static let shared = AYGForwardingManager()

    // MARK: - UserDefaults keys

    private enum Keys {
        static let allowRestrictedForwarding = "AYG.forwarding.allowRestrictedForwarding"
    }

    // MARK: - Storage

    private let defaults = AYGSharedDefaults.store
    /// `NSRecursiveLock` for the same reason the other managers use one: a setter posts
    /// the change notification, an observer can read the setting straight back, and a
    /// plain lock (or a `DispatchQueue.sync`) deadlocks on that re-entry.
    private let lock = NSRecursiveLock()

    private var cached: AYGForwardingSettings?

    private init() {}

    // MARK: - Notifications

    /// Posted after the setting changes. Chat content and history state are recomputed
    /// from peer/message data, so a screen already on-screen listens for this to re-ask.
    public static let settingsChangedNotification = Notification.Name("AYGForwardingSettingsChanged")

    private func notifySettingsChanged() {
        NotificationCenter.default.post(name: AYGForwardingManager.settingsChangedNotification, object: nil)
    }

    // MARK: - The whole record

    public var settings: AYGForwardingSettings {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.loadLocked()
    }

    private func loadLocked() -> AYGForwardingSettings {
        if let cached = self.cached {
            return cached
        }
        var result = AYGForwardingSettings.default
        // `object(forKey:)` rather than `bool(forKey:)`: the default is `true`, and
        // `bool(forKey:)` cannot tell "never written" from "written false".
        if let value = self.defaults.object(forKey: Keys.allowRestrictedForwarding) as? NSNumber {
            result.allowRestrictedForwarding = value.boolValue
        }
        self.cached = result
        return result
    }

    /// Read-modify-write the whole record under one lock, writing and notifying only if
    /// something actually changed.
    public func update(_ f: (inout AYGForwardingSettings) -> Void) {
        self.lock.lock()
        var settings = self.loadLocked()
        let previous = settings
        f(&settings)
        guard settings != previous else {
            self.lock.unlock()
            return
        }
        self.cached = settings
        self.defaults.set(settings.allowRestrictedForwarding, forKey: Keys.allowRestrictedForwarding)
        self.lock.unlock()

        self.notifySettingsChanged()
    }

    // MARK: - Individual settings

    public var allowRestrictedForwarding: Bool {
        get {
            return self.settings.allowRestrictedForwarding
        }
        set {
            self.update { $0.allowRestrictedForwarding = newValue }
        }
    }

    // MARK: - The question every enforcement site asks

    /// Whether the local content-protection gates should be treated as off.
    ///
    /// This is the single predicate the ~40 enforcement sites consult. It deliberately
    /// reads the same as `allowRestrictedForwarding` today; it exists as its own name so
    /// that a later condition (per-account, per-peer exclusions the way Ghost Mode has
    /// them) lands in one place instead of forty.
    public var ignoresCopyProtection: Bool {
        // AYG: always on, which is AyuGram's own behaviour — it has no setting for this
        // at all, it renames the `noforwards` TL field so every stock gate reads a
        // permanently-false flag. `allowRestrictedForwarding` is kept as storage for a
        // later per-peer exclusion, but nothing reads it as an on/off switch today.
        return true
    }
}
