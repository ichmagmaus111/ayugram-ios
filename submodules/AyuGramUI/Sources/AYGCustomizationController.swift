import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext
import MergeLists

// AYG: Customization. A one-for-one port of AyuGram for Android's
// `CustomizationPreferencesActivity.fillItems` — same rows, same order, same copy.
//
// Every row on this screen writes through `AYGCustomizationManager` (TelegramCore),
// which persists to the App Group defaults under `AYG.customization.`. What reads it:
//
//   * "Translucent Deleted Messages" and "Deleted Mark" — the chat bubble. The item
//     node dims `mainContextSourceNode.contentNode` and the status node draws the mark
//     left of the timestamp.
//   * "Local Telegram Premium" — `AYGLocalPremiumManager`, which asserts `.isPremium`
//     on the account user in the postbox and keeps re-asserting it after server syncs.
//   * "Disable Ads" — `AdMessagesHistoryContext` and `_internal_searchAdPeers`.
//   * "Display Ghost Mode Status" — stored, not yet drawn: AyuGram puts a ghost glyph
//     where the chat list's emoji status goes, which is not this port's to touch yet.
//
// AyuGram raises no bulletins on this screen — the only feedback it gives is the
// ripple and the one-time local-premium alert, both of which are here.
//
// AyuGram's "AyuGram Push Service" row is deliberately absent: it toggles Android's
// foreground keep-alive service, which has no iOS counterpart — pushes here come
// from APNs whether the app is running or not.
//
// The Android screen's "App Navigation" and "Pill Stack" rows are deliberately
// absent: both open screens AyuGram for Android inherits from its base client, and their settings
// (tablet mode, bottom bar, drawer, search pills) have no counterpart here.

// Computed, not a stored `let`: a global `let` is evaluated once and cached, so it
// would keep the language the app happened to launch in.
private var aygDeletedMarkTitles: [String] {
    return [
        aygString("DeletedMarkNothing"),
        aygString("DeletedMarkTrashBin"),
        aygString("DeletedMarkCross"),
        aygString("DeletedMarkEyeCrossed")
    ]
}

// AYG: the artwork and the 1dp eye-crossed nudge now live on `AYGDeletedMark` in
// TelegramCore, next to the stored value — the chat bubble needs the same names and a
// second table here would drift from it.

// AYG: the message Android's `DeletedMessagePreviewCell` puts in the preview bubble.
// A hardcoded literal in the APK, not a `LocaleController` string — it is only
// reachable through lsparanoid's string obfuscator, and this is what it decodes to.
private var aygDeletedMessagePreviewText: String { aygString("AYGCustomizationPreviewText") }

// AYG: `date = (now / 1000) - 3540`, i.e. the bubble is stamped 59 minutes ago.
private let aygDeletedMessagePreviewAge: Int32 = 3540

// AYG: `AyuMessageUtils.deletedColors` is `AYGCustomizationSettings.deletedMarkColors`
// in TelegramCore, for the same reason the artwork names are: the chat bubble resolves
// the very same index — 0 meaning the theme's own `chat_inTimeText`, N meaning
// `deletedMarkColors[N - 1]` — and the table cannot exist twice.

// AYG: tags the one row whose node has to be found again after the fact — the
// local-premium switch, which anchors its ripple.
private struct AYGCustomizationItemTag: ItemListItemTag {
    let value: Int32

    func isEqual(to other: ItemListItemTag) -> Bool {
        if let other = other as? AYGCustomizationItemTag {
            return self.value == other.value
        }
        return false
    }
}

private enum AYGCustomizationSection: Int32 {
    case customization
    case usefulFeatures
}

// AYG: the picker's swatches. Index 0 is not in `AyuMessageUtils.deletedColors` —
// Android prepends the theme's own in-bubble timestamp colour, and `deletedIconColor
// == 0` means exactly that.
private func aygDeletedMarkPalette(theme: PresentationTheme) -> [UIColor] {
    var colors: [UIColor] = [theme.chat.message.incoming.secondaryTextColor]
    for value in AYGCustomizationSettings.deletedMarkColors {
        colors.append(UIColor(rgb: value))
    }
    return colors
}

private final class AYGCustomizationArguments {
    let context: AccountContext
    let toggleSemiTransparent: (Bool) -> Void
    let openDeletedMark: () -> Void
    let selectDeletedMarkColor: (Int) -> Void
    let toggleLocalPremium: (Bool) -> Void
    let toggleDisableAds: (Bool) -> Void
    let toggleDisplayGhostStatus: (Bool) -> Void

    init(
        context: AccountContext,
        toggleSemiTransparent: @escaping (Bool) -> Void,
        openDeletedMark: @escaping () -> Void,
        selectDeletedMarkColor: @escaping (Int) -> Void,
        toggleLocalPremium: @escaping (Bool) -> Void,
        toggleDisableAds: @escaping (Bool) -> Void,
        toggleDisplayGhostStatus: @escaping (Bool) -> Void
    ) {
        self.context = context
        self.toggleSemiTransparent = toggleSemiTransparent
        self.openDeletedMark = openDeletedMark
        self.selectDeletedMarkColor = selectDeletedMarkColor
        self.toggleLocalPremium = toggleLocalPremium
        self.toggleDisableAds = toggleDisableAds
        self.toggleDisplayGhostStatus = toggleDisplayGhostStatus
    }
}

private enum AYGCustomizationEntry: ItemListNodeEntry {
    case customizationHeader(String)
    // The chat-specific halves of PresentationData that ItemListPresentationData
    // does not carry, plus the three settings the preview reflects.
    case messagesPreview(TelegramWallpaper, PresentationFontSize, PresentationChatBubbleCorners, Int32, Bool, AYGDeletedMark, Int)
    case semiTransparent(Bool)
    case deletedMark(AYGDeletedMark)
    case deletedMarkColor(Int)
    case usefulHeader(String)
    case localPremium(Bool)
    case disableAds(Bool)
    case displayGhostStatus(Bool)

    var section: ItemListSectionId {
        switch self {
        case .customizationHeader, .messagesPreview, .semiTransparent, .deletedMark, .deletedMarkColor:
            return AYGCustomizationSection.customization.rawValue
        case .usefulHeader, .localPremium, .disableAds, .displayGhostStatus:
            return AYGCustomizationSection.usefulFeatures.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .customizationHeader: return 0
        case .messagesPreview: return 1
        case .semiTransparent: return 2
        case .deletedMark: return 3
        case .deletedMarkColor: return 4
        case .usefulHeader: return 7
        case .localPremium: return 9
        case .disableAds: return 10
        case .displayGhostStatus: return 11
        }
    }

    static func <(lhs: AYGCustomizationEntry, rhs: AYGCustomizationEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AYGCustomizationArguments
        switch self {
        case let .customizationHeader(text), let .usefulHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .messagesPreview(wallpaper, chatFontSize, chatBubbleCorners, timestamp, translucent, mark, colorIndex):
            // Android's `DeletedMessagesCell`: one incoming bubble on the current
            // wallpaper, stamped an hour ago, flagged deleted — so the switch, the
            // mark and the mark's colour can all be watched taking effect.
            var markImage: UIImage?
            if let iconName = mark.inlineImageName {
                markImage = UIImage(bundleImageName: iconName)
            }
            return AYGChatPreviewItem(
                context: arguments.context,
                systemStyle: .glass,
                theme: presentationData.theme,
                componentTheme: presentationData.theme,
                strings: presentationData.strings,
                sectionId: self.section,
                fontSize: chatFontSize,
                chatBubbleCorners: chatBubbleCorners,
                wallpaper: wallpaper,
                dateTimeFormat: presentationData.dateTimeFormat,
                nameDisplayOrder: presentationData.nameDisplayOrder,
                messageItems: [AYGChatPreviewMessageItem(outgoing: false, text: aygDeletedMessagePreviewText, timestamp: timestamp, deleted: true)],
                translucentDeleted: translucent,
                deletedMark: markImage,
                deletedMarkColor: aygDeletedMarkPalette(theme: presentationData.theme)[colorIndex],
                deletedMarkOffsetX: CGFloat(mark.inlineOffsetX)
            )
        case let .semiTransparent(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygString("SemiTransparentDeletedMessages"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleSemiTransparent(value)
            })
        case let .deletedMark(mark):
            // Android puts the mark's own glyph in the value slot and leaves it empty
            // for "Nothing". `.textWithIcon` rather than `.image`: it parks the glyph
            // where a value label would end, which is where Android draws it, and
            // tints it itself with `itemSecondaryTextColor` — `.image` hardcodes a
            // 30pt right offset meant for a disclosure arrow this row does not have.
            // (Android tints with the in-bubble timestamp colour, a shade off this.)
            var labelStyle: ItemListDisclosureLabelStyle = .text
            if let iconName = mark.previewImageName, let icon = UIImage(bundleImageName: iconName) {
                labelStyle = .textWithIcon(icon)
            }
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: aygString("DeletedMarkText"), label: "", labelStyle: labelStyle, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.openDeletedMark()
            })
        case let .deletedMarkColor(index):
            let colors = aygDeletedMarkPalette(theme: presentationData.theme)
            return AYGCustomColorGridItem(presentationData: presentationData, systemStyle: .glass, colors: colors, selectedIndex: index, sectionId: self.section, selected: { index in
                arguments.selectDeletedMarkColor(index)
            })
        case let .localPremium(value):
            // Tagged so the ripple can be anchored on this row's node.
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygString("LocalPremium"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleLocalPremium(value)
            }, tag: AYGCustomizationItemTag(value: AYGCustomizationEntry.localPremium(false).stableId))
        case let .disableAds(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygString("DisableAds"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleDisableAds(value)
            })
        case let .displayGhostStatus(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygString("DisplayGhostStatus"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleDisplayGhostStatus(value)
            })
        }
    }
}

private func aygCustomizationEntries(presentationData: PresentationData, previewTimestamp: Int32, state: AYGCustomizationSettings) -> [AYGCustomizationEntry] {
    var entries: [AYGCustomizationEntry] = [
        .customizationHeader(aygString("CustomizationHeader").uppercased()),
        // Android opens the block with `DeletedMessagesCell`, above the switch.
        .messagesPreview(presentationData.chatWallpaper, presentationData.chatFontSize, presentationData.chatBubbleCorners, previewTimestamp, state.semiTransparentDeletedMessages, state.deletedMark, state.deletedMarkColor),
        .semiTransparent(state.semiTransparentDeletedMessages),
        .deletedMark(state.deletedMark)
    ]
    // The colour grid only exists while a mark is actually drawn.
    if state.deletedMark != .none {
        entries.append(.deletedMarkColor(state.deletedMarkColor))
    }
    entries.append(.usefulHeader(aygString("QoLTogglesHeader").uppercased()))
    entries.append(.localPremium(state.localPremium))
    entries.append(.disableAds(state.disableAds))
    entries.append(.displayGhostStatus(state.displayGhostStatus))
    return entries
}

// AYG: the Customization category screen.
public func aygCustomizationController(context: AccountContext) -> ViewController {
    // The manager is the state. `statePromise` only exists to push a redraw — every
    // write goes through `AYGCustomizationManager`, so a value set here and a value set
    // by an extension or by the anti-delete screen cannot disagree.
    let manager = AYGCustomizationManager.shared
    let statePromise = ValuePromise(manager.settings, ignoreRepeated: true)
    let updateState: ((inout AYGCustomizationSettings) -> Void) -> Void = { f in
        manager.update(f)
        statePromise.set(manager.settings)
    }

    // Local premium has to be re-asserted once per process, and the account user's row
    // in the postbox is only rewritten while a keeper is running — so start one as soon
    // as the screen that owns the switch exists. See the note in `AYGLocalPremiumManager`
    // about the second call site this port does not own.
    if manager.localPremium {
        AYGLocalPremiumManager.shared.keepPremiumFlag(account: context.account)
    }

    var presentControllerImpl: ((ViewController) -> Void)?
    var presentLocalPremiumAlertImpl: (() -> Void)?
    var playLocalPremiumRippleImpl: (() -> Void)?

    // Stamped once, when the screen is built, exactly as Android stamps the message
    // once in `DeletedMessagesCell`'s constructor.
    // AYG: Telegram's own chat previews use this fixed stamp; a live "now - 59min"
    // made the status line render a full date, which the real AyuGram preview has
    // none of — and the mark, positioned by measuring the time alone, landed inside it.
    let previewTimestamp: Int32 = 66000

    let arguments = AYGCustomizationArguments(context: context, toggleSemiTransparent: { value in
        updateState { state in
            state.semiTransparentDeletedMessages = value
        }
    }, openDeletedMark: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = [ActionSheetTextItem(title: aygString("DeletedMarkText"))]
        for (index, title) in aygDeletedMarkTitles.enumerated() {
            guard let mark = AYGDeletedMark(rawValue: index) else {
                continue
            }
            items.append(ActionSheetButtonItem(title: title, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                updateState { state in
                    state.deletedMark = mark
                }
            }))
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(actionSheet)
    }, selectDeletedMarkColor: { index in
        updateState { state in
            state.deletedMarkColor = index
        }
    }, toggleLocalPremium: { value in
        var shouldWarn = false
        updateState { state in
            state.localPremium = value
            // Android warns only when switching it ON, and only the first time ever —
            // `AyuConfig.sawLocalPremiumAlert` is persisted, and so is this.
            if value && !state.sawLocalPremiumAlert {
                state.sawLocalPremiumAlert = true
                shouldWarn = true
            }
        }
        // Writing the flag is only half of it: the account user's `.isPremium` has to be
        // put into (or taken out of) the postbox, and kept there across server syncs.
        if value {
            AYGLocalPremiumManager.shared.keepPremiumFlag(account: context.account)
            // Android plays the ripple on every switch-on, warned or not.
            playLocalPremiumRippleImpl?()
        } else {
            AYGLocalPremiumManager.shared.stopKeepingPremiumFlag()
            let _ = AYGLocalPremiumManager.shared.updatePremiumFlag(account: context.account, enabled: false).start()
        }
        if shouldWarn {
            // Android delays the dialog by 350ms so it lands after the row animates.
            Queue.mainQueue().after(0.35) {
                presentLocalPremiumAlertImpl?()
            }
        }
    }, toggleDisableAds: { value in
        updateState { state in
            state.disableAds = value
        }
    }, toggleDisplayGhostStatus: { value in
        updateState { state in
            state.displayGhostStatus = value
        }
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(AYGSettingsCategory.customization.title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: aygCustomizationEntries(presentationData: presentationData, previewTimestamp: previewTimestamp, state: state),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    playLocalPremiumRippleImpl = { [weak controller] in
        guard let controller, let window = controller.view.window else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        // Anchor on the row that was tapped; Android uses the exact touch point.
        var origin = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        if let itemNode = controller.itemNode(forTag: AYGCustomizationItemTag(value: AYGCustomizationEntry.localPremium(false).stableId)) {
            origin = itemNode.view.convert(CGPoint(x: itemNode.bounds.midX, y: itemNode.bounds.midY), to: window)
        }
        aygPlayRipple(in: window, at: origin, color: presentationData.theme.list.itemAccentColor)
    }
    presentLocalPremiumAlertImpl = { [weak controller] in
        guard let controller else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        // Title is R.string.AppName, message is LocalPremiumAlert, one OK button.
        controller.present(textAlertController(
            context: context,
            title: aygAppName,
            text: aygString("LocalPremiumAlert"),
            actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]
        ), in: .window(.root))
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}

// MARK: - Colour grid

// AYG: the inline row of colour swatches under "Deleted Mark". Android builds it
// out of `PeerColorActivity.PeerColorGrid` with `setOverrideColors` — eight
// circles in one row, the first being the theme's own timestamp colour. ItemListUI
// has no colour-picker item and this module cannot reach PeerInfoUI's, so the row
// is drawn here: one image node for the whole strip plus a tap recogniser that
// maps the touch back to a swatch index.
private final class AYGCustomColorGridItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let systemStyle: ItemListSystemStyle
    let colors: [UIColor]
    let selectedIndex: Int
    let sectionId: ItemListSectionId
    let selected: (Int) -> Void

    init(presentationData: ItemListPresentationData, systemStyle: ItemListSystemStyle, colors: [UIColor], selectedIndex: Int, sectionId: ItemListSectionId, selected: @escaping (Int) -> Void) {
        self.presentationData = presentationData
        self.systemStyle = systemStyle
        self.colors = colors
        self.selectedIndex = selectedIndex
        self.sectionId = sectionId
        self.selected = selected
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = AYGCustomColorGridItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))

            node.contentSize = layout.contentSize
            node.insets = layout.insets

            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply() })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? AYGCustomColorGridItemNode else {
                assertionFailure()
                return
            }
            let makeLayout = nodeValue.asyncLayout()
            async {
                let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
                Queue.mainQueue().async {
                    completion(layout, { _ in apply() })
                }
            }
        }
    }
}

private final class AYGCustomColorGridItemNode: ListViewItemNode, ItemListItemNode {
    private let backgroundNode: ASDisplayNode
    private let topStripeNode: ASDisplayNode
    private let bottomStripeNode: ASDisplayNode
    private let maskNode: ASImageNode
    private let swatchesNode: ASImageNode

    private var item: AYGCustomColorGridItem?
    private var swatchFrames: [CGRect] = []

    var tag: ItemListItemTag? {
        return nil
    }

    init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true

        self.topStripeNode = ASDisplayNode()
        self.topStripeNode.isLayerBacked = true

        self.bottomStripeNode = ASDisplayNode()
        self.bottomStripeNode.isLayerBacked = true

        self.maskNode = ASImageNode()
        self.maskNode.isUserInteractionEnabled = false

        self.swatchesNode = ASImageNode()
        self.swatchesNode.isUserInteractionEnabled = false
        self.swatchesNode.displaysAsynchronously = false
        self.swatchesNode.displayWithoutProcessing = true

        super.init(layerBacked: false)

        self.addSubnode(self.swatchesNode)
    }

    override func didLoad() {
        super.didLoad()

        let recognizer = UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
        self.view.addGestureRecognizer(recognizer)
    }

    @objc private func tapGesture(_ recognizer: UITapGestureRecognizer) {
        guard case .ended = recognizer.state, let item = self.item else {
            return
        }
        let point = recognizer.location(in: self.view)
        for (index, frame) in self.swatchFrames.enumerated() {
            // The tappable area is the whole cell, not just the drawn circle.
            if frame.insetBy(dx: -6.0, dy: -12.0).contains(point) {
                if index != item.selectedIndex {
                    item.selected(index)
                }
                return
            }
        }
    }

    func asyncLayout() -> (_ item: AYGCustomColorGridItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        let currentItem = self.item

        return { [weak self] item, params, neighbors in
            let separatorHeight = UIScreenPixel
            let separatorRightInset: CGFloat = item.systemStyle == .glass ? 16.0 : 0.0

            let leftInset = 16.0 + params.leftInset
            let rightInset = 16.0 + params.rightInset

            let contentHeight: CGFloat = 56.0
            let contentSize = CGSize(width: params.width, height: contentHeight)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)

            let available = max(1.0, params.width - leftInset - rightInset)
            let count = max(1, item.colors.count)
            let cellWidth = available / CGFloat(count)
            let diameter = max(12.0, min(30.0, floor(cellWidth) - 6.0))

            var swatchFrames: [CGRect] = []
            for index in 0 ..< count {
                let centerX = leftInset + cellWidth * (CGFloat(index) + 0.5)
                swatchFrames.append(CGRect(
                    x: floorToScreenPixels(centerX - diameter / 2.0),
                    y: floorToScreenPixels((contentHeight - diameter) / 2.0),
                    width: diameter,
                    height: diameter
                ))
            }

            var updatedTheme: PresentationTheme?
            if currentItem?.presentationData.theme !== item.presentationData.theme {
                updatedTheme = item.presentationData.theme
            }

            let colors = item.colors
            let selectedIndex = item.selectedIndex
            let swatchesImage = generateImage(contentSize, contextGenerator: { size, context in
                context.clear(CGRect(origin: CGPoint(), size: size))
                for (index, frame) in swatchFrames.enumerated() {
                    guard index < colors.count else {
                        break
                    }
                    let color = colors[index]
                    if index == selectedIndex {
                        // Selected swatches get a ring with a gap, the way every
                        // colour picker in the app draws them.
                        context.setStrokeColor(color.cgColor)
                        context.setLineWidth(2.0)
                        context.strokeEllipse(in: frame.insetBy(dx: 1.0, dy: 1.0))
                        context.setFillColor(color.cgColor)
                        context.fillEllipse(in: frame.insetBy(dx: 5.0, dy: 5.0))
                    } else {
                        context.setFillColor(color.cgColor)
                        context.fillEllipse(in: frame)
                    }
                }
            })

            return (layout, { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item
                strongSelf.swatchFrames = swatchFrames

                if let _ = updatedTheme {
                    strongSelf.topStripeNode.backgroundColor = item.presentationData.theme.list.itemBlocksSeparatorColor
                    strongSelf.bottomStripeNode.backgroundColor = item.presentationData.theme.list.itemBlocksSeparatorColor
                    strongSelf.backgroundNode.backgroundColor = item.presentationData.theme.list.itemBlocksBackgroundColor
                }

                if strongSelf.backgroundNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.backgroundNode, at: 0)
                }
                if strongSelf.topStripeNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.topStripeNode, at: 1)
                }
                if strongSelf.bottomStripeNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.bottomStripeNode, at: 2)
                }
                if strongSelf.maskNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.maskNode, at: 3)
                }

                let hasCorners = itemListHasRoundedBlockLayout(params)
                var hasTopCorners = false
                var hasBottomCorners = false
                switch neighbors.top {
                case .sameSection(false):
                    strongSelf.topStripeNode.isHidden = true
                default:
                    hasTopCorners = true
                    strongSelf.topStripeNode.isHidden = hasCorners
                }
                let bottomStripeInset: CGFloat
                switch neighbors.bottom {
                case .sameSection(false):
                    bottomStripeInset = leftInset
                    strongSelf.bottomStripeNode.isHidden = false
                default:
                    bottomStripeInset = 0.0
                    hasBottomCorners = true
                    strongSelf.bottomStripeNode.isHidden = hasCorners
                }

                strongSelf.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(item.presentationData.theme, top: hasTopCorners, bottom: hasBottomCorners, glass: item.systemStyle == .glass) : nil

                strongSelf.backgroundNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: contentSize.height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight)))
                strongSelf.maskNode.frame = strongSelf.backgroundNode.frame.insetBy(dx: params.leftInset, dy: 0.0)
                strongSelf.topStripeNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: separatorHeight))
                strongSelf.bottomStripeNode.frame = CGRect(origin: CGPoint(x: bottomStripeInset, y: contentSize.height - separatorHeight), size: CGSize(width: params.width - params.rightInset - bottomStripeInset - separatorRightInset, height: separatorHeight))

                strongSelf.swatchesNode.image = swatchesImage
                strongSelf.swatchesNode.frame = CGRect(origin: CGPoint(), size: contentSize)
            })
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}
