// AYG: a copy of SettingsUI's AutodownloadSizeLimitItem — the continuous size
// slider with the value written as "up to <size>". It is the counterpart of
// AyuGram for Android's `MaxFileSizeCell`, which is what the two per-connection
// media limits are inside the "Save Attachments" sheet.
//
// Copied rather than imported because SettingsUI already depends on AyuGramUI;
// depending on it the other way round is a build cycle. Copied rather than
// generalised upstream so merges from Telegram stay clean.
//
// Two things differ from the original:
//
//   * it is an `ActionSheetItem`, not a `ListViewItem`. Android draws these two
//     rows inside a BottomSheet and the iOS port of that sheet is an
//     `ActionSheetController`, which hosts `ActionSheetItem`s only — an
//     ItemList item cannot go in one. The slider, its colours, its geometry and
//     the value <-> position mapping are the upstream item's; the row chrome
//     (background, separator, fonts) is `ActionSheetItemNode`'s, so the row sits
//     in the sheet like the checkbox rows above it;
//   * the anchor table is `MaxFileSizeCell`'s, not autodownload's. See below.

import Foundation
import UIKit
import Display
import AsyncDisplayKit
import TelegramPresentationData
import LegacyComponents

// MaxFileSizeCell.onSeekBarDrag / .setSize: four equal quarters of the track,
// each linear in bytes, 500 KB -> 1 MB -> 10 MB -> 100 MB -> 100 MB + 1901 MiB.
// The last anchor really is 2098200576 and not a round 2 GB — the APK's own
// constant is 1993342976.0f added to 104857600 — and Android's formatFileSize
// rounds it to "2.0 GB" on screen.
private let aygMaxFileSizeValues: [(CGFloat, Int64)] = [
    (0.00, 512000),
    (0.25, 1048576),
    (0.50, 10485760),
    (0.75, 104857600),
    (1.00, 2098200576)
]

private func aygSliderValue(for size: Int64) -> CGFloat {
    for i in 1 ..< aygMaxFileSizeValues.count {
        let (previousValue, previousValueSize) = aygMaxFileSizeValues[i - 1]
        let (value, valueSize) = aygMaxFileSizeValues[i]
        if valueSize > size {
            return previousValue + CGFloat(size - previousValueSize) / CGFloat(valueSize - previousValueSize) * (value - previousValue)
        } else if previousValueSize == size {
            return previousValue
        } else if valueSize == size || i == aygMaxFileSizeValues.count - 1 {
            return value
        }
    }
    return 0.0
}

private func aygSizeValue(for sliderValue: CGFloat) -> Int64 {
    for i in 1 ..< aygMaxFileSizeValues.count {
        let (previousValue, previousValueSize) = aygMaxFileSizeValues[i - 1]
        let (value, valueSize) = aygMaxFileSizeValues[i]
        if value > sliderValue {
            let delta = (sliderValue - previousValue) / (value - previousValue) * CGFloat(valueSize - previousValueSize)
            return previousValueSize + Int64(delta)
        } else if previousValue == sliderValue {
            return previousValueSize
        } else if value == sliderValue || i == aygMaxFileSizeValues.count - 1 {
            return valueSize
        }
    }
    return 0
}

public final class AYGMaxFileSizeItem: ActionSheetItem {
    // The knob is the only thing an ActionSheetControllerTheme cannot describe,
    // so the presentation theme comes along for PresentationResourcesItemList.
    let theme: PresentationTheme
    let strings: PresentationStrings
    let decimalSeparator: String
    let title: String
    let value: Int64
    let updated: (Int64) -> Void

    public init(theme: PresentationTheme, strings: PresentationStrings, decimalSeparator: String, title: String, value: Int64, updated: @escaping (Int64) -> Void) {
        self.theme = theme
        self.strings = strings
        self.decimalSeparator = decimalSeparator
        self.title = title
        self.value = value
        self.updated = updated
    }

    public func node(theme: ActionSheetControllerTheme) -> ActionSheetItemNode {
        return AYGMaxFileSizeItemNode(theme: theme, item: self)
    }

    public func updateNode(_ node: ActionSheetItemNode) {
        guard let node = node as? AYGMaxFileSizeItemNode else {
            assertionFailure()
            return
        }

        node.setItem(self)
        node.requestLayoutUpdate()
    }
}

private final class AYGMaxFileSizeItemNode: ActionSheetItemNode {
    private let theme: ActionSheetControllerTheme

    private let titleNode: ImmediateTextNode
    private let labelNode: ImmediateTextNode
    private var sliderView: TGPhotoEditorSliderView?

    private var item: AYGMaxFileSizeItem?
    private var validLayoutSize: CGSize?
    private var currentValue: Int64 = 0

    // ActionSheetItemNode's own `init(theme:)` is `public`, not `open`, so a
    // subclass outside Display cannot override it — every other out-of-module
    // ActionSheetItemNode (LargeEmojiActionSheetItemNode et al.) takes its data
    // through a fresh designated init instead, and so does this one.
    init(theme: ActionSheetControllerTheme, item: AYGMaxFileSizeItem) {
        self.theme = theme

        self.titleNode = ImmediateTextNode()
        self.titleNode.maximumNumberOfLines = 1
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.displaysAsynchronously = false

        self.labelNode = ImmediateTextNode()
        self.labelNode.maximumNumberOfLines = 1
        self.labelNode.isUserInteractionEnabled = false
        self.labelNode.displaysAsynchronously = false

        super.init(theme: theme)

        self.addSubnode(self.titleNode)
        self.addSubnode(self.labelNode)

        self.setItem(item)
    }

    override func didLoad() {
        super.didLoad()

        let sliderView = TGPhotoEditorSliderView()
        sliderView.enablePanHandling = true
        sliderView.trackCornerRadius = 2.0
        sliderView.lineSize = 4.0
        sliderView.dotSize = 5.0
        sliderView.minimumValue = 0.0
        sliderView.maximumValue = 1.0
        sliderView.startValue = 0.0
        sliderView.displayEdges = true
        sliderView.disablesInteractiveTransitionGestureRecognizer = true
        sliderView.backgroundColor = self.theme.itemBackgroundColor
        sliderView.backColor = self.theme.switchFrameColor
        sliderView.startColor = self.theme.switchFrameColor
        sliderView.trackColor = self.theme.controlAccentColor
        if let item = self.item {
            sliderView.knobImage = PresentationResourcesItemList.knobImage(item.theme)
            sliderView.value = aygSliderValue(for: self.currentValue)
        }
        self.view.addSubview(sliderView)
        sliderView.addTarget(self, action: #selector(self.sliderValueChanged), for: .valueChanged)
        self.sliderView = sliderView

        if let size = self.validLayoutSize {
            self.layoutSliderView(size: size)
        }
    }

    func setItem(_ item: AYGMaxFileSizeItem) {
        self.item = item
        self.currentValue = item.value

        let defaultFont = Font.regular(floor(self.theme.baseFontSize * 20.0 / 17.0))
        self.titleNode.attributedText = NSAttributedString(string: item.title, font: defaultFont, textColor: self.theme.primaryTextColor)
        self.updateLabel()

        if let sliderView = self.sliderView {
            sliderView.knobImage = PresentationResourcesItemList.knobImage(item.theme)
            sliderView.value = aygSliderValue(for: item.value)
        }
    }

    private func updateLabel() {
        guard let item = self.item else {
            return
        }
        // Android's MaxFileSizeCell labels itself with AutodownloadSizeLimitUpTo;
        // the iOS string for that is AutoDownloadSettings.UpTo.
        //
        // The upstream item builds its DataSizeStringFormatting through the
        // `init(strings:decimalSeparator:)` convenience, which lives in
        // TelegramStringFormatting — a module AyuGramUI does not depend on. The
        // memberwise initialiser in TelegramPresentationData is the same thing
        // spelled out.
        let strings = item.strings
        let formatting = DataSizeStringFormatting(decimalSeparator: item.decimalSeparator, byte: strings.FileSize_B(_:), kilobyte: strings.FileSize_KB(_:), megabyte: strings.FileSize_MB(_:), gigabyte: strings.FileSize_GB(_:))
        let text = strings.AutoDownloadSettings_UpTo(dataSizeString(self.currentValue, formatting: formatting)).string
        let defaultFont = Font.regular(floor(self.theme.baseFontSize * 20.0 / 17.0))
        self.labelNode.attributedText = NSAttributedString(string: text, font: defaultFont, textColor: self.theme.controlAccentColor)
    }

    private func layoutSliderView(size: CGSize) {
        guard let sliderView = self.sliderView else {
            return
        }
        sliderView.frame = CGRect(origin: CGPoint(x: 15.0, y: 37.0), size: CGSize(width: size.width - 15.0 * 2.0, height: 44.0))
        sliderView.hitTestEdgeInsets = UIEdgeInsets(top: -sliderView.frame.minX, left: 0.0, bottom: 0.0, right: -sliderView.frame.minX)
    }

    public override func updateLayout(constrainedSize: CGSize, transition: ContainedViewLayoutTransition) -> CGSize {
        let size = CGSize(width: constrainedSize.width, height: 88.0)
        self.validLayoutSize = size

        // The title sits in the same column as the checkbox rows above it, which
        // is where Android has it too (both cells indent their text by 21dp).
        let titleOrigin: CGFloat = 50.0
        let labelSize = self.labelNode.updateLayout(CGSize(width: size.width - titleOrigin - 15.0 - 8.0, height: size.height))
        let titleSize = self.titleNode.updateLayout(CGSize(width: max(10.0, size.width - titleOrigin - labelSize.width - 15.0 - 8.0), height: size.height))

        self.titleNode.frame = CGRect(origin: CGPoint(x: titleOrigin, y: floorToScreenPixels((37.0 - titleSize.height) / 2.0)), size: titleSize)
        self.labelNode.frame = CGRect(origin: CGPoint(x: size.width - 15.0 - labelSize.width, y: floorToScreenPixels((37.0 - labelSize.height) / 2.0)), size: labelSize)

        self.layoutSliderView(size: size)

        self.updateInternalLayout(size, constrainedSize: constrainedSize)
        return size
    }

    @objc private func sliderValueChanged() {
        guard let sliderView = self.sliderView, let item = self.item else {
            return
        }

        self.currentValue = aygSizeValue(for: sliderView.value)
        self.updateLabel()
        self.requestLayoutUpdate()
        item.updated(self.currentValue)
    }
}
