import Foundation
import UIKit
import Display
import AppBundle
import TelegramCore

// AYG: the mark AyuGram draws next to a kept-after-deletion message's timestamp.
//
// `ChatMessageCell.setMessageObjectInternal` in the APK builds the time string as
//
//     if (ayuDeleted) {
//         timeString = deletedIcon + " " + timeString;
//         timeWidth += AyuMessageUtils.getDeletedIconWidth();
//     }
//
// — i.e. the glyph goes *immediately left of the time*, inside the same layout, and the
// time layout's measured width grows by exactly the glyph's intrinsic width. There is
// **no date next to the mark**: the message's own timestamp follows it and the deletion
// time is never drawn. That is deliberate on AyuGram's side and is why nothing here
// looks at `DeletedMessageAttribute.deletedAt`.
//
// The artwork is the 14pt `*Inline` set — Android's `Theme.chat_trashBinDrawable` and
// friends, weighted for in-bubble use — not the 22pt `_preview` set the settings row
// and the picker dialog use.

/// Tinted copies of the three inline marks, keyed by mark + colour.
///
/// A cache is not an optimisation here, it is a requirement: the status node's layout
/// runs off-main once per visible message per pass, and `generateTintedImage` allocates
/// and redraws a bitmap every time it is called.
private final class AYGDeletedMarkImageCache {
    static let shared = AYGDeletedMarkImageCache()

    private let lock = NSLock()
    private var images: [Int64: UIImage] = [:]

    /// The tinted mark, or nil when the user has chosen "Nothing" (or the asset is
    /// missing, which would be a packaging bug rather than a runtime condition).
    func image(mark: AYGDeletedMark, color: UIColor) -> UIImage? {
        guard let imageName = mark.inlineImageName else {
            return nil
        }
        let key = (Int64(mark.rawValue) << 32) | Int64(color.argb)

        self.lock.lock()
        if let cached = self.images[key] {
            self.lock.unlock()
            return cached
        }
        self.lock.unlock()

        guard let base = UIImage(bundleImageName: imageName),
              let tinted = generateTintedImage(image: base, color: color) else {
            return nil
        }

        self.lock.lock()
        self.images[key] = tinted
        self.lock.unlock()

        return tinted
    }
}

/// The mark to draw next to a deleted message's timestamp, in the configured colour.
///
/// `defaultColor` is the message type's own in-bubble timestamp colour and is what index
/// 0 of the picker means — AyuGram's `AyuMessageUtils.initializeIcons` only overrides the
/// span's colour `if (AyuConfig.getDeletedIconColor() > 0)`, leaving
/// `Theme.key_chat_inTimeText` in place otherwise.
func aygDeletedMarkStatusImage(defaultColor: UIColor) -> UIImage? {
    let settings = AYGCustomizationManager.shared.settings
    guard settings.deletedMark != .none else {
        return nil
    }
    var color = defaultColor
    if let value = AYGCustomizationSettings.deletedMarkColorValue(settings.deletedMarkColor) {
        color = UIColor(rgb: value)
    }
    return AYGDeletedMarkImageCache.shared.image(mark: settings.deletedMark, color: color)
}

/// `AyuMessageUtils.initializeIcons` nudges the eye-crossed span 1dp left, and only that
/// one. Applied to the drawn frame rather than baked into the artwork so the reserved
/// width stays the glyph's own.
var aygDeletedMarkStatusOffsetX: CGFloat {
    return CGFloat(AYGCustomizationManager.shared.settings.deletedMark.inlineOffsetX)
}
