import Foundation

// AYG: Process/container plumbing shared by the anti-delete managers.
//
// Everything here is deliberately dependency-free: TelegramCore must never
// import UIKit or Display, and the port carries none of the source fork's
// remote-config / paywall machinery. The only cross-process channel is the
// App Group container, which is derived from the bundle id exactly the way
// `NotificationService.swift`, `Share/ShareRootController.swift` and friends
// derive it — there is no shared "BuildConfig" reachable from this module.

enum AYGRuntimeEnvironment {
    /// True when this code runs inside an app extension (Notification Service
    /// Extension, Share, Siri, …). Extensions share TelegramCore but have their
    /// own container, so they cannot write the main app's archive — and they
    /// must never be the ones to seed the shared settings store, since their
    /// own `UserDefaults.standard` is empty (see `AYGSharedDefaults`).
    static let isAppExtensionProcess: Bool = {
        return Bundle.main.bundleURL.pathExtension == "appex"
    }()

    /// `group.<base bundle id>`. In an extension the bundle id carries one extra
    /// component (`ph.telegra.Telegraph.NotificationService`), which is stripped
    /// — same derivation the app's own extensions use.
    static let appGroupName: String? = {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return nil
        }
        var baseAppBundleId = bundleIdentifier
        if AYGRuntimeEnvironment.isAppExtensionProcess {
            guard let lastDotRange = bundleIdentifier.range(of: ".", options: [.backwards]) else {
                return nil
            }
            baseAppBundleId = String(bundleIdentifier[..<lastDotRange.lowerBound])
        }
        return "group.\(baseAppBundleId)"
    }()

    static let appGroupContainerURL: URL? = {
        guard let appGroupName = AYGRuntimeEnvironment.appGroupName else {
            return nil
        }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName)
    }()

    /// Defaults shared with the extensions. Every AYG setting lives here now —
    /// see `AYGSharedDefaults`, which owns the suite and the one-time migration
    /// off `UserDefaults.standard`. Kept as an optional alias because the
    /// capture flag below wants to know whether the group is genuinely
    /// available rather than silently writing to a local fallback.
    static let sharedDefaults: UserDefaults? = {
        guard AYGRuntimeEnvironment.appGroupName != nil else {
            return nil
        }
        return AYGSharedDefaults.store
    }()
}

/// Raw name of `UIApplicationDidBecomeActiveNotification`. Observed by string so
/// TelegramCore keeps its "no UIKit" rule; the managers use it to drain whatever
/// an extension journalled while the app was in the background.
let aygApplicationDidBecomeActiveNotificationName = Notification.Name("UIApplicationDidBecomeActiveNotification")

/// Likewise `UIApplicationWillResignActiveNotification` — the cue to flush any
/// debounced write before the app can be suspended or killed.
let aygApplicationWillResignActiveNotificationName = Notification.Name("UIApplicationWillResignActiveNotification")
