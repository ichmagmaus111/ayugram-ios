import Foundation

// AYG: the value types behind the Customization screen. Split out of the manager the
// same way `AYGGhostModeSettings` is, so the manager file is only storage plus the
// questions the rendering sites ask it.
//
// Ported from AyuGram for Android's `AyuConfig` — the five settings
// `CustomizationPreferencesActivity.fillItems` writes (`semiTransparentDeletedMessages`,
// `deletedIcon`, `deletedIconColor`, `localPremium`, `disableAds`, `displayGhostStatus`)
// plus the `sawLocalPremiumAlert` marker. Defaults are AyuConfig's own
// `BooleanPref`/`IntegerPref` initialisers, verbatim.

/// Which glyph is drawn next to a kept-after-deletion message's timestamp.
///
/// Raw values are persisted and are AyuGram's own `deletedIcon` ints, so the two
/// clients agree on what a backed-up value means. Renaming a case migrates nothing.
public enum AYGDeletedMark: Int, Codable, CaseIterable {
    case none = 0
    case trashBin = 1
    case cross = 2
    case eyeCrossed = 3

    /// The asset drawn *inside* a bubble. Android uses `Theme.chat_trashBinDrawable`
    /// and friends here — the 14dp artwork, not the 22dp `_preview` set the settings
    /// row and the picker use.
    public var inlineImageName: String? {
        switch self {
        case .none:
            return nil
        case .trashBin:
            return "AyuGram/AYGCustomMarkTrashBinInline"
        case .cross:
            return "AyuGram/AYGCustomMarkCrossInline"
        case .eyeCrossed:
            return "AyuGram/AYGCustomMarkEyeCrossedInline"
        }
    }

    /// The 22dp artwork the settings row's value slot and the picker dialog use
    /// (`AyuMessageUtils.getDeletedIconPreviewDrawable`, which returns null for `.none`).
    public var previewImageName: String? {
        switch self {
        case .none:
            return nil
        case .trashBin:
            return "AyuGram/AYGCustomMarkTrashBin"
        case .cross:
            return "AyuGram/AYGCustomMarkCross"
        case .eyeCrossed:
            return "AyuGram/AYGCustomMarkEyeCrossed"
        }
    }

    /// `AyuMessageUtils.initializeIcons` nudges the eye-crossed span 1dp left, and only
    /// that one. Everything else draws where the layout puts it.
    public var inlineOffsetX: Double {
        switch self {
        case .eyeCrossed:
            return -1.0
        default:
            return 0.0
        }
    }
}

/// One record of everything the Customization screen owns.
///
/// Every field decodes with a default, so a record written by an older build reads back
/// without losing the fields it does have — same contract as `AYGGhostModeSettings`.
public struct AYGCustomizationSettings: Codable, Equatable {
    /// Draw kept-after-deletion messages translucent. AyuGram defaults this **on**.
    public var semiTransparentDeletedMessages: Bool
    public var deletedMark: AYGDeletedMark
    /// Index into `AYGCustomizationSettings.deletedMarkPalette`, where **0 means the
    /// theme's own in-bubble timestamp colour** and N means `deletedMarkColors[N - 1]`.
    /// That off-by-one is AyuGram's: `AyuMessageUtils.initializeIcons` only overrides
    /// the span colour `if (AyuConfig.getDeletedIconColor() > 0)`.
    public var deletedMarkColor: Int
    public var localPremium: Bool
    /// AyuGram defaults this **on**: sponsored messages are hidden until asked for.
    public var disableAds: Bool
    public var displayGhostStatus: Bool
    /// AyuGram's `sawLocalPremiumAlert` — the "no increased limits" warning is shown
    /// once ever, not once per visit.
    public var sawLocalPremiumAlert: Bool

    public init(
        semiTransparentDeletedMessages: Bool = true,
        deletedMark: AYGDeletedMark = .trashBin,
        deletedMarkColor: Int = 0,
        localPremium: Bool = false,
        disableAds: Bool = true,
        displayGhostStatus: Bool = false,
        sawLocalPremiumAlert: Bool = false
    ) {
        self.semiTransparentDeletedMessages = semiTransparentDeletedMessages
        self.deletedMark = deletedMark
        self.deletedMarkColor = deletedMarkColor
        self.localPremium = localPremium
        self.disableAds = disableAds
        self.displayGhostStatus = displayGhostStatus
        self.sawLocalPremiumAlert = sawLocalPremiumAlert
    }

    public static let `default` = AYGCustomizationSettings()

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AYGCustomizationSettings.default
        self.semiTransparentDeletedMessages = try container.decodeIfPresent(Bool.self, forKey: .semiTransparentDeletedMessages) ?? fallback.semiTransparentDeletedMessages
        self.deletedMark = try container.decodeIfPresent(AYGDeletedMark.self, forKey: .deletedMark) ?? fallback.deletedMark
        self.deletedMarkColor = try container.decodeIfPresent(Int.self, forKey: .deletedMarkColor) ?? fallback.deletedMarkColor
        self.localPremium = try container.decodeIfPresent(Bool.self, forKey: .localPremium) ?? fallback.localPremium
        self.disableAds = try container.decodeIfPresent(Bool.self, forKey: .disableAds) ?? fallback.disableAds
        self.displayGhostStatus = try container.decodeIfPresent(Bool.self, forKey: .displayGhostStatus) ?? fallback.displayGhostStatus
        self.sawLocalPremiumAlert = try container.decodeIfPresent(Bool.self, forKey: .sawLocalPremiumAlert) ?? fallback.sawLocalPremiumAlert
    }

    // MARK: - Palette

    /// `AyuMessageUtils.deletedColors`, verbatim, as 0xRRGGBB.
    ///
    /// Lives here rather than in the settings screen because the chat bubble needs the
    /// same list: `deletedMarkColor` is an *index*, and two copies of the table would
    /// drift. TelegramCore may not import UIKit, so these stay raw components.
    public static let deletedMarkColors: [UInt32] = [
        0xff0000,
        0xdc2626,
        0xdb2777,
        0xc026d3,
        0x9333ea,
        0x4f46e5,
        0x2563eb
    ]

    /// The explicit colour for `deletedMarkColor`, or `nil` for "use the theme's own
    /// in-bubble timestamp colour" — which is what index 0 means.
    public static func deletedMarkColorValue(_ index: Int) -> UInt32? {
        guard index > 0, index - 1 < AYGCustomizationSettings.deletedMarkColors.count else {
            return nil
        }
        return AYGCustomizationSettings.deletedMarkColors[index - 1]
    }

    /// How many entries the picker shows: the theme colour plus every explicit one.
    public static var deletedMarkPaletteCount: Int {
        return AYGCustomizationSettings.deletedMarkColors.count + 1
    }
}
