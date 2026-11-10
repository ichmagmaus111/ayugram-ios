import Foundation

// AYG: One `UserDefaults` for every fork-owned setting, shared with the app extensions.
//
// The fork originally kept its settings in `UserDefaults.standard`. That works
// inside the app and nowhere else: the Notification Service, Share and Siri
// extensions get their own `standard` domain, so Ghost Mode looked disabled to
// them and the Share extension happily sent read receipts and typing packets
// the app would have suppressed. Everything now lives in the App Group suite
// instead, which all of them can see.
//
// The group is the one the app already declares in its entitlements
// (`group.<bundle id>`, see `Telegram/BUILD`), derived by
// `AYGRuntimeEnvironment.appGroupName`.
public enum AYGSharedDefaults {
    /// Every key this fork writes starts with this, which is what makes a
    /// blanket migration safe — nothing of Telegram's own is touched.
    private static let keyPrefix = "AYG."

    /// Set once the copy below has run, so it never runs twice and never
    /// resurrects a setting the user has since changed.
    private static let migrationMarkerKey = "AYG.sharedDefaults.migratedFromStandard"

    /// The store every AYG manager reads and writes.
    ///
    /// Falls back to `.standard` only if the group is unavailable, which would
    /// mean the entitlement is missing — the app keeps working, extensions just
    /// stay blind, exactly as before this file existed.
    public static let store: UserDefaults = {
        guard let appGroupName = AYGRuntimeEnvironment.appGroupName,
              let shared = UserDefaults(suiteName: appGroupName) else {
            return UserDefaults.standard
        }
        AYGSharedDefaults.migrateFromStandardIfNeeded(into: shared)
        return shared
    }()

    /// Copies existing `AYG.*` settings out of `UserDefaults.standard` on first
    /// launch after the switch, so nobody's Ghost Mode or anti-delete
    /// configuration silently resets.
    ///
    /// Only the main app migrates. An extension can start before the app has
    /// ever run, and its `standard` domain is a *different* one — letting it
    /// migrate would seed the group with an extension's empty defaults and then
    /// mark the job done, wiping the user's real settings.
    ///
    /// Keys already present in the group win, and the source keys are left in
    /// place: the migration is a copy, not a move, so downgrading to a build
    /// from before this change still finds its settings.
    private static func migrateFromStandardIfNeeded(into shared: UserDefaults) {
        if AYGRuntimeEnvironment.isAppExtensionProcess {
            return
        }
        if shared.bool(forKey: AYGSharedDefaults.migrationMarkerKey) {
            return
        }

        let standard = UserDefaults.standard
        for (key, value) in standard.dictionaryRepresentation() where key.hasPrefix(AYGSharedDefaults.keyPrefix) {
            if shared.object(forKey: key) == nil {
                shared.set(value, forKey: key)
            }
        }
        shared.set(true, forKey: AYGSharedDefaults.migrationMarkerKey)
    }
}
