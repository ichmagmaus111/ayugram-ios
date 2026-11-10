import Foundation

// The brand this app wears, for the places in upstream code that name the app:
// the single app-icon entry and its label, and the default-browser preview.
// Mirrors `xtg_brand_*` in build-system/xtg_flavor.bzl (Info.plist names, icons,
// the Telegram → brand string rename). In TelegramCore so that every module can
// read it; touches nothing but Foundation.

/// User-visible name of the app.
public let xtgBrandName: String = "AyuGram"

/// Prefix of the brand's asset names: `<prefix>Icon` is the app-icon picker entry
/// (and the `.alticon` folder), `<prefix>IntroLogo` the onboarding mark.
public let xtgBrandAssetPrefix: String = "AYG"

/// Name of the single alternate-icon entry (`AYGIcon`).
public let xtgBrandIconName: String = xtgBrandAssetPrefix + "Icon"
