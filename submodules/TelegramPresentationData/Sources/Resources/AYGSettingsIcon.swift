import Foundation
import UIKit
import Display
import AppBundle

// AYG: the AyuGram row's icon in Settings.
//
// This used to draw the full-colour app logo clipped to a rounded square, which read
// as a sticker among Telegram's own rows — every one of those is a white glyph on a
// tinted, gradient-lit tile. AyuGram for Android has the same split: the launcher
// carries the coloured artwork, while the in-app row uses `ic_foreground_solid_ayu`,
// the mark as a flat white shape.
//
// So this now hands that same glyph to Telegram's own `renderSettingsIcon`, which
// means the gradient, the `plusLighter` sheen, the `overlay` backdrop and the 8pt
// corner radius all come from upstream and stay correct if upstream restyles them.
// `AYGSettingsGlyph.imageset` is `ic_foreground_solid_ayu`'s four paths, rendered
// from the APK with `build-system/AYGRenderVectorPath.swift`.
//
// The coloured logo is not gone — it is still what the AyuGram screen's own header
// shows (`AYGAppMark`), which is exactly where Android keeps it too.
public extension PresentationResourcesSettings {
    static let ayugram = renderSettingsIcon(name: "Item List/Icons/AYGSettingsGlyph", backgroundColors: [colorViolet])
}
