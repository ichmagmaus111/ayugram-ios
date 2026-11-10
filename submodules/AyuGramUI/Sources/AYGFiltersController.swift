import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import AppBundle
import MergeLists
import UndoUI

// AYG: Filters. A one-for-one port of AyuGram for Android's
// `FiltersPreferencesActivity.fillItems` — same rows, same order, same copy —
// plus the two screens it pushes into (`FiltersListPreferencesActivity`,
// `FiltersShadowBanPreferencesActivity`) and the filter editor
// (`RegexFilterEditActivity`).
//
// The list screen carries Android's whole action bar: the `+`, the
// `msg_blur_radial` button that excludes a shared filter from one dialog, and
// the long-press multi-select mode with its Done / toggle-enabled / Delete
// action mode. `ItemListControllerState` takes a `secondaryRightNavigationButton:`
// as well as a `rightNavigationButton:`, which is what makes two buttons fit.
//
// Import and export use the real format, decompiled from
// `AyuFilterUtils` — see `AYGFiltersBackup.swift`.
//
// The model, the storage and the matching engine live in
// `//submodules/TelegramCore/Sources/AYGFilters`; this file is the four screens
// and nothing else. A filter typed here is persisted to `AYGSharedDefaults` and
// enforced in `ChatHistoryListNode` (the chat) and `ChatListNodeEntries` (the
// chat-list preview), so it takes effect the moment Done is pressed.

// MARK: - Model

// One state, shared by all four screens, so the counters on the Filters screen
// move the moment a filter is added two screens deeper — and, unlike the earlier
// UI-only version of this file, the same state the engine reads.
//
// `AYGFiltersManager` is the storage and serialises its own writes; this is the
// `ValuePromise` face of it that the ItemList signals want. The promise is seeded
// from the manager and then driven by its `stateSignal`, so a write made on any
// screen — or by an import — lands on all of them.
final class AYGFiltersModel {
    let statePromise: ValuePromise<AYGFiltersState>

    private let context: AccountContext
    private var stateDisposable: Disposable?
    private var peerResolveDisposable: Disposable?
    private var blockedPeersContext: BlockedPeersContext?
    private var blockedPeersDisposable: Disposable?

    init(context: AccountContext) {
        self.context = context
        self.statePromise = ValuePromise(AYGFiltersManager.shared.state, ignoreRepeated: true)
        self.stateDisposable = (AYGFiltersManager.shared.stateSignal
        |> deliverOnMainQueue).start(next: { [weak self] state in
            self?.statePromise.set(state)
        })
        self.startResolvingPeers()
    }

    deinit {
        self.stateDisposable?.dispose()
        self.peerResolveDisposable?.dispose()
        self.blockedPeersDisposable?.dispose()
    }

    var current: AYGFiltersState {
        return AYGFiltersManager.shared.state
    }

    func update(_ f: (AYGFiltersState) -> AYGFiltersState) {
        AYGFiltersManager.shared.update(f)
    }

    // MARK: - Peer resolution

    // `AyuMessageUtils.getDialogInAnyWay`: turn the stored `dialogId`s back into
    // peers so the rows can show a name and an avatar instead of a raw number.
    //
    // A negative id is ambiguous between a legacy group and a channel, so both
    // are asked for and whichever exists wins — see `aygFiltersCandidatePeerIds`.
    // Writing the answers back into the state makes `stateSignal` fire again,
    // but the next pass asks only for the ids that are *still* unresolved, and
    // `distinctUntilChanged` stops the loop there.
    private func startResolvingPeers() {
        let context = self.context
        self.peerResolveDisposable = (AYGFiltersManager.shared.stateSignal
        |> map { state -> [Int64] in
            var dialogIds = state.dialogIds
            dialogIds.append(contentsOf: state.shadowBanned)
            var seen = Set<Int64>()
            return dialogIds.filter { dialogId in
                if state.peers[dialogId] != nil || seen.contains(dialogId) {
                    return false
                }
                seen.insert(dialogId)
                return true
            }
        }
        |> distinctUntilChanged
        |> mapToSignal { dialogIds -> Signal<[Int64: EnginePeer], NoError> in
            if dialogIds.isEmpty {
                return .single([:])
            }
            var peerIds: [EnginePeer.Id] = []
            for dialogId in dialogIds {
                peerIds.append(contentsOf: aygFiltersCandidatePeerIds(dialogId))
            }
            return context.engine.data.get(EngineDataMap(peerIds.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) }))
            |> map { peers -> [Int64: EnginePeer] in
                var result: [Int64: EnginePeer] = [:]
                for (peerId, peer) in peers {
                    if let peer {
                        result[aygFiltersDialogId(peerId)] = peer
                    }
                }
                return result
            }
        }
        |> deliverOnMainQueue).start(next: { resolved in
            if resolved.isEmpty {
                return
            }
            AYGFiltersManager.shared.update { current in
                var current = current
                for (dialogId, peer) in resolved {
                    current.peers[dialogId] = peer
                }
                return current
            }
        })
    }

    // MARK: - Blocked peers

    // `getMessagesController().getBlockedPeersFull(true)`, which Android calls the
    // moment "Hide from Blocked Users" goes on.
    //
    // There is no postbox-resident blocked list here, so this pages
    // `BlockedPeersContext` to the end and hands the ids to `AYGFiltersManager`,
    // which persists them for the engine to test against. Called on the Filters
    // screen appearing and when the switch is turned on — the same two moments.
    func refreshBlockedPeers() {
        if self.blockedPeersContext != nil {
            return
        }
        let blockedPeersContext = BlockedPeersContext(account: self.context.account, subject: .blocked)
        self.blockedPeersContext = blockedPeersContext
        self.blockedPeersDisposable = (blockedPeersContext.state
        |> deliverOnMainQueue).start(next: { [weak blockedPeersContext] state in
            if state.isLoadingMore {
                return
            }
            AYGFiltersManager.shared.updateBlockedPeerIds(state.peers.compactMap { $0.peerId })
            if state.canLoadMore {
                blockedPeersContext?.loadMore()
            }
        })
    }
}

// MARK: - Copy

private func aygFiltersAmount(_ count: Int) -> String {
    return aygPluralString("RegexFiltersAmount", count)
}

private func aygFiltersExcludedAmount(_ count: Int) -> String {
    return aygPluralString("RegexFiltersExcludedAmount", count)
}

// Android's `AyuMessageUtils.shortify(name, 20)` on the list screen's title.
private func aygShortify(_ text: String, _ limit: Int) -> String {
    if text.count <= limit {
        return text
    }
    return String(text.prefix(limit)) + "\u{2026}"
}

private let aygFiltersRegex101Url = "https://regex101.com/r/3XHb17"

// MARK: - Navigation bar buttons

// The action bar's overflow menu (`R.drawable.ic_ab_other`). Reuse ONE instance
// across state emissions: `ItemListNavigationButtonContent.node` compares by
// identity, so a fresh node each time rebuilds the bar button every update.
private final class AYGFiltersMoreButtonNode: ASDisplayNode {
    // AYG: a node used as a bar button MUST report its size here. Without it
    // ASDisplayNode hands the navigation bar an unconstrained size and the button
    // stretches across the whole bar, swallowing the title.
    override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        return CGSize(width: 30.0, height: 30.0)
    }

    private let iconNode: ASImageNode

    override init() {
        self.iconNode = ASImageNode()
        self.iconNode.displaysAsynchronously = false
        self.iconNode.displayWithoutProcessing = true

        super.init()

        let size = CGSize(width: 30.0, height: 30.0)
        self.frame = CGRect(origin: CGPoint(), size: size)
        self.iconNode.frame = CGRect(origin: CGPoint(), size: size)
        self.addSubnode(self.iconNode)
    }

    func update(theme: PresentationTheme) {
        self.iconNode.image = PresentationResourcesRootController.navigationMoreCircledIcon(theme)
    }
}

// The action bar's icon buttons that iOS has no `ItemListNavigationButtonContentIcon`
// for: `msg_blur_radial` (exclude a shared filter) and `msg_noise_on` /
// `msg_noise_off` (enable / disable the selection). Both glyphs are the real
// ones out of the APK. Same identity rule as the button above — one instance
// per controller, updated in place.
//
// Note that a `.node` button must be the *primary* `rightNavigationButton`:
// `ItemListController` wires a custom-node bar button straight to the primary
// action, whatever slot it sits in. So the icon goes on the primary and the
// plain one on the secondary, which is also the order Android draws them in.
private final class AYGFiltersIconButtonNode: ASDisplayNode {
    // AYG: a node used as a bar button MUST report its size here. Without it
    // ASDisplayNode hands the navigation bar an unconstrained size and the button
    // stretches across the whole bar, swallowing the title.
    override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        return CGSize(width: 30.0, height: 30.0)
    }

    private let iconNode: ASImageNode
    private var currentImageName: String?
    private var currentTheme: PresentationTheme?

    override init() {
        self.iconNode = ASImageNode()
        self.iconNode.displaysAsynchronously = false
        self.iconNode.displayWithoutProcessing = true

        super.init()

        self.frame = CGRect(origin: CGPoint(), size: CGSize(width: 30.0, height: 30.0))
        self.iconNode.frame = CGRect(origin: CGPoint(x: 3.0, y: 3.0), size: CGSize(width: 24.0, height: 24.0))
        self.addSubnode(self.iconNode)
    }

    func update(theme: PresentationTheme, imageName: String) {
        if self.currentImageName == imageName, let currentTheme = self.currentTheme, currentTheme === theme {
            return
        }
        self.currentImageName = imageName
        self.currentTheme = theme
        self.iconNode.image = generateTintedImage(image: UIImage(bundleImageName: "AyuGram/\(imageName)"), color: theme.rootController.navigationBar.buttonColor)
    }
}

// MARK: - Icons

// Android draws these two as avatars: `msg_folders_groups` on an orange circle
// for Shared Filters, `ayu_eye_crossed` on a grey one for Shadow Ban. Both
// glyphs are lifted from the APK; the fork tints them like every other row icon
// rather than reproducing the avatar circles.
private func aygFiltersSharedIcon(theme: PresentationTheme) -> UIImage? {
    return generateTintedImage(image: UIImage(bundleImageName: "AyuGram/AYGFiltersShared"), color: theme.list.itemSecondaryTextColor)
}

private func aygFiltersShadowBanIcon(theme: PresentationTheme) -> UIImage? {
    return generateTintedImage(image: UIImage(bundleImageName: "AyuGram/AYGFiltersShadowBan"), color: theme.list.itemSecondaryTextColor)
}

// MARK: - Bulletins

// Android's `BulletinFactory.of(this).createSimpleBulletin(...)`. `R.raw.info`
// and `R.raw.contact_check` have exact counterparts here; `R.raw.error` does
// not, and falls back to the info bulletin.
//
// Every string below is `docs/AYGAndroidStrings.xml` verbatim, named after the
// key it comes from, and each is raised at the point the APK raises it — the
// call sites carry the decompiled method name.
var aygFiltersHideFromBlockedNote: String { aygString("FiltersHideFromBlockedNote") }
var aygFiltersToastFailImport: String { aygString("FiltersToastFailImport") }
var aygFiltersToastFailFetch: String { aygString("FiltersToastFailFetch") }
var aygFiltersToastFailPublish: String { aygString("FiltersToastFailPublish") }
var aygFiltersToastFailNoChanges: String { aygString("FiltersToastFailNoChanges") }
var aygFiltersToastSuccess: String { aygString("FiltersToastSuccess") }
var aygRegexFiltersAddError: String { aygString("RegexFiltersAddError") }
var aygRegexFilterBulletinText: String { aygString("RegexFilterBulletinText") }
var aygRegexFilterBulletinAction: String { aygString("RegexFilterBulletinAction") }

private func aygFiltersPresentBulletin(context: AccountContext, controller: ViewController?, content: UndoOverlayContent, action: @escaping (UndoOverlayAction) -> Bool = { _ in return false }) {
    guard let controller else {
        return
    }
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    controller.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, animateInAsReplacement: false, action: action), in: .window(.root))
}

private func aygFiltersErrorContent(_ text: String) -> UndoOverlayContent {
    return .info(title: nil, text: text, timeout: nil, customUndoText: nil)
}

// MARK: - Filters screen

private enum AYGFiltersSection: Int32 {
    case general
    case lists
    case dialogs
}

private final class AYGFiltersArguments {
    let context: AccountContext
    let toggleFiltersEnabled: (Bool) -> Void
    let toggleFiltersInChats: (Bool) -> Void
    let toggleHideFromBlocked: (Bool) -> Void
    let openSharedFilters: () -> Void
    let openShadowBan: () -> Void
    let openDialogFilters: (Int64) -> Void
    let openMenu: () -> Void

    init(
        context: AccountContext,
        toggleFiltersEnabled: @escaping (Bool) -> Void,
        toggleFiltersInChats: @escaping (Bool) -> Void,
        toggleHideFromBlocked: @escaping (Bool) -> Void,
        openSharedFilters: @escaping () -> Void,
        openShadowBan: @escaping () -> Void,
        openDialogFilters: @escaping (Int64) -> Void,
        openMenu: @escaping () -> Void
    ) {
        self.context = context
        self.toggleFiltersEnabled = toggleFiltersEnabled
        self.toggleFiltersInChats = toggleFiltersInChats
        self.toggleHideFromBlocked = toggleHideFromBlocked
        self.openSharedFilters = openSharedFilters
        self.openShadowBan = openShadowBan
        self.openDialogFilters = openDialogFilters
        self.openMenu = openMenu
    }
}

private enum AYGFiltersEntry: ItemListNodeEntry {
    case generalHeader(String)
    case filtersEnabled(Bool)
    case filtersInChats(Bool)
    case hideFromBlocked(Bool)
    case sharedFilters(String)
    case shadowBan(String)
    case dialog(Int32, Int64, EnginePeer?, String, String)

    var section: ItemListSectionId {
        switch self {
        case .generalHeader, .filtersEnabled, .filtersInChats, .hideFromBlocked:
            return AYGFiltersSection.general.rawValue
        // Android's `UItem.asShadow()` between the blocks — a plain shadow with
        // no text, which on iOS is simply the next section.
        case .sharedFilters, .shadowBan:
            return AYGFiltersSection.lists.rawValue
        case .dialog:
            return AYGFiltersSection.dialogs.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .generalHeader: return 0
        case .filtersEnabled: return 1
        case .filtersInChats: return 2
        case .hideFromBlocked: return 3
        case .sharedFilters: return 4
        case .shadowBan: return 5
        case let .dialog(index, _, _, _, _): return 100 + index
        }
    }

    static func <(lhs: AYGFiltersEntry, rhs: AYGFiltersEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AYGFiltersArguments
        switch self {
        case let .generalHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .filtersEnabled(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygString("RegexFiltersEnable"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleFiltersEnabled(value)
            })
        case let .filtersInChats(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygString("RegexFiltersEnableSharedInChats"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleFiltersInChats(value)
            })
        case let .hideFromBlocked(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygString("FiltersHideFromBlocked"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleHideFromBlocked(value)
            })
        case let .sharedFilters(count):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: aygFiltersSharedIcon(theme: presentationData.theme), title: aygString("RegexFiltersShared"), label: "", additionalDetailLabel: count, sectionId: self.section, style: .blocks, action: {
                arguments.openSharedFilters()
            })
        case let .shadowBan(count):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: aygFiltersShadowBanIcon(theme: presentationData.theme), title: aygString("FiltersShadowBan"), label: "", additionalDetailLabel: count, sectionId: self.section, style: .blocks, action: {
                arguments.openShadowBan()
            })
        case let .dialog(_, dialogId, peer, title, subtitle):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, context: arguments.context, iconPeer: peer, title: title, label: "", additionalDetailLabel: subtitle, sectionId: self.section, style: .blocks, action: {
                arguments.openDialogFilters(dialogId)
            })
        }
    }
}

private func aygFiltersEntries(presentationData: PresentationData, state: AYGFiltersState) -> [AYGFiltersEntry] {
    var entries: [AYGFiltersEntry] = []

    entries.append(.generalHeader(aygString("CategoryGeneral").uppercased()))
    entries.append(.filtersEnabled(state.filtersEnabled))
    entries.append(.filtersInChats(state.sharedFiltersInChats))
    entries.append(.hideFromBlocked(state.hideFromBlocked))

    entries.append(.sharedFilters(aygFiltersAmount(state.sharedFilters.count)))
    entries.append(.shadowBan(aygFiltersAmount(state.shadowBanned.count)))

    var index: Int32 = 0
    for dialogId in state.dialogIds {
        let peer = state.peers[dialogId]
        let plus = state.filters(dialogId: dialogId).count
        let minus = state.exclusions.filter({ $0.dialogId == dialogId }).count

        var subtitle = ""
        if plus > 0 {
            subtitle.append(aygFiltersAmount(plus))
        }
        if plus > 0 && minus > 0 {
            subtitle.append(", ")
        }
        if minus > 0 {
            subtitle.append(aygFiltersExcludedAmount(minus))
        }

        // Android: the dialog's name, "?" when it resolves to a nameless peer,
        // and the raw id when it does not resolve at all.
        var title: String
        if let peer {
            title = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
            if title.isEmpty {
                title = "?"
            }
        } else {
            title = "\(dialogId)"
        }
        entries.append(.dialog(index, dialogId, peer, title, subtitle))
        index += 1
    }

    return entries
}

// MARK: - Filter list screen (Shared Filters, and one per dialog)

private enum AYGFiltersListSection: Int32 {
    case filters
    case exclusions
}

// Android's `FiltersListPreferencesActivity.SelectionKind`. The action mode only
// ever holds one kind at a time: selecting a filter and an excluded filter
// together would need two different Delete actions.
private enum AYGFiltersSelectionKind: Equatable {
    case filter
    case exclusion
}

private struct AYGFiltersListSelection: Equatable {
    var kind: AYGFiltersSelectionKind?
    var ids: Set<UUID> = []

    // `isSelectionMode()`: a kind on its own is not enough, the set has to be
    // non-empty too.
    var isActive: Bool {
        return self.kind != nil && !self.ids.isEmpty
    }
}

private final class AYGFiltersListArguments {
    let selectFilter: (UUID) -> Void
    let selectExclusion: (UUID) -> Void
    let longPressFilter: (UUID) -> Void
    let longPressExclusion: (UUID) -> Void

    init(
        selectFilter: @escaping (UUID) -> Void,
        selectExclusion: @escaping (UUID) -> Void,
        longPressFilter: @escaping (UUID) -> Void,
        longPressExclusion: @escaping (UUID) -> Void
    ) {
        self.selectFilter = selectFilter
        self.selectExclusion = selectExclusion
        self.longPressFilter = longPressFilter
        self.longPressExclusion = longPressExclusion
    }
}

private enum AYGFiltersListEntry: ItemListNodeEntry {
    case filtersHeader(String)
    // index, id, text, isEnabled, isSelecting, isSelected
    case filter(Int32, UUID, String, Bool, Bool, Bool)
    case exclusionsHeader(String)
    // index, id, text, isSelecting, isSelected
    case exclusion(Int32, UUID, String, Bool, Bool)
    case empty(String)

    var section: ItemListSectionId {
        switch self {
        case .filtersHeader, .filter, .empty:
            return AYGFiltersListSection.filters.rawValue
        case .exclusionsHeader, .exclusion:
            return AYGFiltersListSection.exclusions.rawValue
        }
    }

    // A row swaps between `ItemListActionItem` and `ItemListCheckboxItem` when
    // the action mode comes up, and `ListViewItem.updateNode` only ever updates
    // a node of its own class — an item that changes class under a stable id
    // silently drops the update transaction. So the two forms carry different
    // ids and the list rebuilds those rows instead of updating them. The blocks
    // stay in order: filters below the header at 0, exclusions below theirs at
    // 10000, the empty caption last.
    var stableId: Int32 {
        switch self {
        case .filtersHeader: return 0
        case let .filter(index, _, _, _, isSelecting, _): return (isSelecting ? 5000 : 100) + index
        case .exclusionsHeader: return 10000
        case let .exclusion(index, _, _, isSelecting, _): return (isSelecting ? 15100 : 10100) + index
        case .empty: return 20000
        }
    }

    static func <(lhs: AYGFiltersListEntry, rhs: AYGFiltersListEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AYGFiltersListArguments
        switch self {
        case let .filtersHeader(text), let .exclusionsHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .filter(_, id, text, isEnabled, isSelecting, isSelected):
            // Android tints the row background while it is selected; iOS says the
            // same thing with the checkmark it already has for multi-selection.
            if isSelecting {
                return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: text, style: .left, checked: isSelected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                    arguments.selectFilter(id)
                })
            }
            // Android's `UItem.asButton(...)`, greyed with `.gray()` when the
            // filter is switched off.
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: isEnabled ? .neutral : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.selectFilter(id)
            }, longTapAction: {
                arguments.longPressFilter(id)
            })
        case let .exclusion(_, id, text, isSelecting, isSelected):
            if isSelecting {
                return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: text, style: .left, checked: isSelected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                    arguments.selectExclusion(id)
                })
            }
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .neutral, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.selectExclusion(id)
            }, longTapAction: {
                arguments.longPressExclusion(id)
            })
        case let .empty(text):
            // Android's `UItem.asShadow(text)`: a shadow that carries a caption.
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

// The filters a list screen shows. `chooseFor` is the dialog the
// `msg_blur_radial` button opened this screen for: Android's `setReduce` hides
// the shared filters that dialog already excludes, since excluding them twice
// would be a no-op.
private func aygFiltersListFilters(state: AYGFiltersState, dialogId: Int64?, chooseFor: Int64?) -> (filters: [AYGRegexFilter], exclusions: [AYGRegexFilter]) {
    if let chooseFor {
        let excluded = Set(state.exclusions.filter({ $0.dialogId == chooseFor }).map({ $0.filterId }))
        return (state.sharedFilters.filter({ !excluded.contains($0.id) }), [])
    }
    if let dialogId {
        return (state.filters(dialogId: dialogId), state.exclusions(dialogId: dialogId))
    }
    return (state.sharedFilters, [])
}

private func aygFiltersListEntries(state: AYGFiltersState, dialogId: Int64?, chooseFor: Int64?, selection: AYGFiltersListSelection) -> [AYGFiltersListEntry] {
    var entries: [AYGFiltersListEntry] = []

    let (filters, exclusions) = aygFiltersListFilters(state: state, dialogId: dialogId, chooseFor: chooseFor)

    let selectingFilters = selection.isActive && selection.kind == .filter
    let selectingExclusions = selection.isActive && selection.kind == .exclusion

    if !filters.isEmpty {
        entries.append(.filtersHeader(aygString("RegexFiltersHeader").uppercased()))
        var index: Int32 = 0
        for filter in filters {
            entries.append(.filter(index, filter.id, filter.text, filter.isEnabled, selectingFilters, selection.ids.contains(filter.id)))
            index += 1
        }
    }

    if !exclusions.isEmpty {
        entries.append(.exclusionsHeader(aygString("RegexFiltersExcluded").uppercased()))
        var index: Int32 = 0
        for filter in exclusions {
            entries.append(.exclusion(index, filter.id, filter.text, selectingExclusions, selection.ids.contains(filter.id)))
            index += 1
        }
    }

    if filters.isEmpty && exclusions.isEmpty {
        entries.append(.empty(aygString("RegexFiltersListEmpty")))
    }

    return entries
}

// MARK: - Shadow Ban screen

private enum AYGFiltersShadowBanSection: Int32 {
    case peers
}

private final class AYGFiltersShadowBanArguments {
    let context: AccountContext
    let openPeer: (Int64) -> Void

    init(context: AccountContext, openPeer: @escaping (Int64) -> Void) {
        self.context = context
        self.openPeer = openPeer
    }
}

private enum AYGFiltersShadowBanEntry: ItemListNodeEntry {
    case header(String)
    case peer(Int32, Int64, EnginePeer, String, String)
    case empty(String)

    var section: ItemListSectionId {
        return AYGFiltersShadowBanSection.peers.rawValue
    }

    var stableId: Int32 {
        switch self {
        case .header: return 0
        case let .peer(index, _, _, _, _): return 100 + index
        case .empty: return 20000
        }
    }

    static func <(lhs: AYGFiltersShadowBanEntry, rhs: AYGFiltersShadowBanEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AYGFiltersShadowBanArguments
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .peer(_, dialogId, peer, title, subtitle):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, context: arguments.context, iconPeer: peer, title: title, label: "", additionalDetailLabel: subtitle, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.openPeer(dialogId)
            })
        case let .empty(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func aygFiltersShadowBanEntries(presentationData: PresentationData, state: AYGFiltersState) -> [AYGFiltersShadowBanEntry] {
    var entries: [AYGFiltersShadowBanEntry] = []

    if state.shadowBanned.isEmpty {
        entries.append(.empty(aygString("RegexFiltersListEmpty")))
        return entries
    }

    entries.append(.header(aygString("RegexFiltersHeader").uppercased()))
    var index: Int32 = 0
    for dialogId in state.shadowBanned {
        guard let peer = state.peers[dialogId] else {
            continue
        }
        // Android labels the row with what the peer *is*, not its name — the
        // name comes from the peer itself.
        let subtitle: String
        switch peer {
        case let .user(user):
            subtitle = user.botInfo != nil ? aygString("AYGFiltersPeerBot") : aygString("AYGFiltersPeerUser")
        case .legacyGroup, .channel:
            subtitle = aygString("AYGFiltersPeerChannel")
        default:
            subtitle = ""
        }
        entries.append(.peer(index, dialogId, peer, peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder), subtitle))
        index += 1
    }

    return entries
}

// MARK: - Filter editor

private enum AYGRegexFilterEditSection: Int32 {
    case expression
    case options
}

private struct AYGRegexFilterEditState: Equatable {
    var text: String = ""
    var isEnabled: Bool = true
    var caseInsensitive: Bool = true
    var reversed: Bool = false
    // `RegexFilterEditActivity.errorTextView`: the `PatternSyntaxException`'s own
    // message, shown under the field and cleared on the next keystroke.
    var errorText: String?
}

private final class AYGRegexFilterEditArguments {
    let context: AccountContext
    let updateText: (String) -> Void
    let toggleEnabled: () -> Void
    let toggleCaseInsensitive: () -> Void
    let toggleReversed: () -> Void
    let openHelp: () -> Void

    init(
        context: AccountContext,
        updateText: @escaping (String) -> Void,
        toggleEnabled: @escaping () -> Void,
        toggleCaseInsensitive: @escaping () -> Void,
        toggleReversed: @escaping () -> Void,
        openHelp: @escaping () -> Void
    ) {
        self.context = context
        self.updateText = updateText
        self.toggleEnabled = toggleEnabled
        self.toggleCaseInsensitive = toggleCaseInsensitive
        self.toggleReversed = toggleReversed
        self.openHelp = openHelp
    }
}

private enum AYGRegexFilterEditEntry: ItemListNodeEntry {
    case expression(String)
    case expressionError(String)
    case expressionFooter(String)
    case enabled(Bool)
    case caseInsensitive(Bool)
    case reversed(Bool)

    var section: ItemListSectionId {
        switch self {
        case .expression, .expressionError, .expressionFooter:
            return AYGRegexFilterEditSection.expression.rawValue
        case .enabled, .caseInsensitive, .reversed:
            return AYGRegexFilterEditSection.options.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .expression: return 0
        case .expressionError: return 1
        case .expressionFooter: return 2
        case .enabled: return 3
        case .caseInsensitive: return 4
        case .reversed: return 5
        }
    }

    static func <(lhs: AYGRegexFilterEditEntry, rhs: AYGRegexFilterEditEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AYGRegexFilterEditArguments
        switch self {
        case let .expression(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: ""), text: text, placeholder: aygString("RegexFiltersPlaceholder"), type: .regular(capitalization: false, autocorrection: false), clearType: .always, sectionId: self.section, textUpdated: { value in
                arguments.updateText(value)
            }, action: {})
        case let .expressionError(text):
            // Android puts the `PatternSyntaxException` message under the field
            // in `key_text_RedRegular`. `ItemListTextItem` has no destructive
            // variant, so the colour comes in with the string.
            let attributedText = NSAttributedString(
                string: text,
                font: Font.regular(presentationData.fontSize.itemListBaseHeaderFontSize),
                textColor: presentationData.theme.list.itemDestructiveColor
            )
            return ItemListTextItem(presentationData: presentationData, text: .custom(context: arguments.context, string: attributedText), sectionId: self.section)
        case let .expressionFooter(text):
            // Android puts this behind a `msg_help_14` button in the action bar,
            // next to Done — there is room for it here too, but the alert it
            // opens links to a regex101 URL built out of lsparanoid-obfuscated
            // string chunks (the flags depend on Case Insensitive), so the
            // button is left out rather than pointed at a guessed URL. The link
            // in this footer is the one `RegexFiltersAddDescription` ships with.
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section, linkAction: { action in
                switch action {
                case .tap:
                    arguments.openHelp()
                }
            })
        case let .enabled(value):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: aygString("EnableExpression"), style: .left, checked: value, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.toggleEnabled()
            })
        case let .caseInsensitive(value):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: aygString("CaseInsensitiveExpression"), style: .left, checked: value, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.toggleCaseInsensitive()
            })
        case let .reversed(value):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: aygString("ReversedExpression"), style: .left, checked: value, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.toggleReversed()
            })
        }
    }
}

private func aygRegexFilterEditEntries(state: AYGRegexFilterEditState) -> [AYGRegexFilterEditEntry] {
    var entries: [AYGRegexFilterEditEntry] = [.expression(state.text)]
    if let errorText = state.errorText, !errorText.isEmpty {
        entries.append(.expressionError(errorText))
    }
    entries.append(.expressionFooter(aygString("AYGFiltersExpressionFooter", aygFiltersRegex101Url)))
    entries.append(.enabled(state.isEnabled))
    entries.append(.caseInsensitive(state.caseInsensitive))
    entries.append(.reversed(state.reversed))
    return entries
}

// `dialogId` is the dialog a new filter belongs to, nil for a shared one.
// `initialText` is Android's third constructor argument: the editor opened from
// inside a chat with a message's text pre-filled. It changes two things, exactly
// as `RegexFilterEditActivity` does — the new filter is created **shared**
// (`dialogId = initialText == null ? dialogId : null`), and saving raises the
// `RegexFilterBulletinText` bulletin whose action moves it to `dialogId` after
// all.
private func aygRegexFilterEditController(context: AccountContext, model: AYGFiltersModel, dialogId: Int64?, filterId: UUID?, initialText: String? = nil) -> ViewController {
    let existing = filterId.flatMap { id in model.current.filters.first(where: { $0.id == id }) }

    var initialState = AYGRegexFilterEditState()
    if let existing {
        initialState.text = existing.text
        initialState.isEnabled = existing.isEnabled
        initialState.caseInsensitive = existing.caseInsensitive
        initialState.reversed = existing.reversed
    } else if let initialText {
        initialState.text = initialText
    }

    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((AYGRegexFilterEditState) -> AYGRegexFilterEditState) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }

    var dismissImpl: (() -> Void)?
    var getNavigationControllerImpl: (() -> NavigationController?)?
    var presentBulletinImpl: ((UndoOverlayContent, @escaping (UndoOverlayAction) -> Bool) -> Void)?
    var presentBulletinAfterDismissImpl: ((UndoOverlayContent, @escaping (UndoOverlayAction) -> Bool) -> Void)?

    let arguments = AYGRegexFilterEditArguments(context: context, updateText: { text in
        updateState { current in
            var state = current
            state.text = text
            // Android clears the error as soon as the field changes.
            state.errorText = nil
            return state
        }
    }, toggleEnabled: {
        updateState { current in
            var state = current
            state.isEnabled = !state.isEnabled
            return state
        }
    }, toggleCaseInsensitive: {
        updateState { current in
            var state = current
            state.caseInsensitive = !state.caseInsensitive
            return state
        }
    }, toggleReversed: {
        updateState { current in
            var state = current
            state.reversed = !state.reversed
            return state
        }
    }, openHelp: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        context.sharedContext.openExternalUrl(
            context: context,
            urlContext: .generic,
            url: aygFiltersRegex101Url,
            forceExternal: false,
            presentationData: presentationData,
            navigationController: getNavigationControllerImpl?(),
            dismissInput: {}
        )
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        // `RegexFilterEditActivity.AnonymousClass1.onItemClick(2)` — the Done
        // button. Two ways to fail, both of them loud and neither of them saving:
        // an empty expression, and one `Pattern.compile` rejects.
        //
        // This is the whole reason a malformed expression cannot end up in
        // storage. `AYGFilterEngine` also refuses to compile a bad pattern, but
        // silently — it has to, because an imported backup can carry a Java
        // regex that ICU will not take — so this check is the only place a
        // person is ever told.
        let rightNavigationButton = ItemListNavigationButton(content: .text(presentationData.strings.Common_Done), style: .bold, enabled: !state.text.isEmpty, action: {
            let trimmed = state.text
            if trimmed.isEmpty {
                presentBulletinImpl?(aygFiltersErrorContent(aygRegexFiltersAddError), { _ in return false })
                return
            }
            if let error = AYGFilterEngine.validationError(pattern: trimmed) {
                updateState { current in
                    var current = current
                    current.errorText = error
                    return current
                }
                presentBulletinImpl?(aygFiltersErrorContent(aygRegexFiltersAddError), { _ in return false })
                return
            }

            // Android: opened from a chat, a new filter is shared regardless of
            // which dialog it was opened from — the bulletin below is what
            // offers to pin it to that dialog after the fact.
            let newFilterDialogId = initialText == nil ? dialogId : nil
            let newFilterId = UUID()
            model.update { current in
                var current = current
                if let filterId, let index = current.filters.firstIndex(where: { $0.id == filterId }) {
                    current.filters[index].text = trimmed
                    current.filters[index].isEnabled = state.isEnabled
                    current.filters[index].caseInsensitive = state.caseInsensitive
                    current.filters[index].reversed = state.reversed
                } else {
                    current.filters.append(AYGRegexFilter(id: newFilterId, dialogId: newFilterDialogId, text: trimmed, isEnabled: state.isEnabled, caseInsensitive: state.caseInsensitive, reversed: state.reversed))
                }
                return current
            }
            // Android schedules the bulletin *then* calls `finishFragment()`, and
            // the order matters here too: popping detaches the controller from
            // its navigation controller, so the host the bulletin needs has to be
            // captured before the pop, not after.
            if initialText != nil, existing == nil, let dialogId {
                // `RegexFilterBulletinText` with its `RegexFilterBulletinAction`
                // button, raised on whatever is left on screen after this editor
                // pops — Android waits 300 ms and shows it on the `chatActivity`
                // it was opened from.
                presentBulletinAfterDismissImpl?(.info(title: nil, text: aygRegexFilterBulletinText, timeout: nil, customUndoText: aygRegexFilterBulletinAction), { action in
                    guard case .undo = action else {
                        return false
                    }
                    // `$r8$lambda$IZfdp78wD3kjDCNBNQt2FB8_1ws`: move the filter
                    // out of the shared list and onto the dialog it came from.
                    AYGFiltersManager.shared.update { current in
                        var current = current
                        if let index = current.filters.firstIndex(where: { $0.id == newFilterId }) {
                            current.filters[index].dialogId = dialogId
                        }
                        return current
                    }
                    return true
                })
            }
            dismissImpl?()
        })

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(existing == nil ? aygString("RegexFiltersAdd") : aygString("RegexFiltersEdit")),
            leftNavigationButton: nil,
            rightNavigationButton: rightNavigationButton,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: aygRegexFilterEditEntries(state: state),
            style: .blocks,
            animateChanges: false
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    dismissImpl = { [weak controller] in
        let _ = controller?.navigationController?.popViewController(animated: true)
    }
    getNavigationControllerImpl = { [weak controller] in
        return controller?.navigationController as? NavigationController
    }
    presentBulletinImpl = { [weak controller] content, action in
        aygFiltersPresentBulletin(context: context, controller: controller, content: content, action: action)
    }
    presentBulletinAfterDismissImpl = { [weak controller] content, action in
        // The editor is on its way out, so the bulletin has to land on whatever
        // is underneath it — the chat it was opened from. The navigation
        // controller is read now, while this controller is still attached to it;
        // the 0.3 s is Android's own `runOnUIThread(..., 300L)`, long enough for
        // the pop animation to finish so the top controller is the right one.
        let navigationController = controller?.navigationController as? NavigationController
        Queue.mainQueue().after(0.3, {
            guard let host = navigationController?.viewControllers.last as? ViewController else {
                return
            }
            aygFiltersPresentBulletin(context: context, controller: host, content: content, action: action)
        })
    }
    return controller
}

// AYG: the in-chat entry point, `new RegexFilterEditActivity(dialogId, null, text, chatActivity)`.
//
// Android reaches it from the message context menu ("Add filter" on a selection),
// which lives in the chat message path this change does not own — so nothing
// calls this yet. Everything downstream of the call is here and wired: the
// pre-filled expression, the shared-not-dialog placement, and the
// `RegexFilterBulletinText` / `RegexFilterBulletinAction` bulletin that moves the
// new filter to the chat it was created in.
public func aygRegexFilterAddController(context: AccountContext, peerId: EnginePeer.Id, initialText: String) -> ViewController {
    return aygRegexFilterEditController(context: context, model: AYGFiltersModel(context: context), dialogId: aygFiltersDialogId(peerId), filterId: nil, initialText: initialText)
}

// MARK: - Import from URL

private enum AYGFiltersImportUrlSection: Int32 {
    case url
}

private final class AYGFiltersImportUrlArguments {
    let updateUrl: (String) -> Void

    init(updateUrl: @escaping (String) -> Void) {
        self.updateUrl = updateUrl
    }
}

private enum AYGFiltersImportUrlEntry: ItemListNodeEntry {
    case url(String)

    var section: ItemListSectionId {
        return AYGFiltersImportUrlSection.url.rawValue
    }

    var stableId: Int32 {
        return 0
    }

    static func <(lhs: AYGFiltersImportUrlEntry, rhs: AYGFiltersImportUrlEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AYGFiltersImportUrlArguments
        switch self {
        case let .url(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: ""), text: text, placeholder: aygString("FiltersImportURL"), type: .regular(capitalization: false, autocorrection: false), clearType: .always, sectionId: self.section, textUpdated: { value in
                arguments.updateUrl(value)
            }, action: {})
        }
    }
}

// Android puts this in an `AlertDialog` with an `EditTextSettingsCell` in it.
// The alert this fork's `textAlertController` builds is an `AlertScreen`, whose
// input field lives in `//submodules/TelegramUI/Components/AlertComponent` —
// not a dependency of this module — so the same field is shown as its own
// screen, with `FiltersImportAction` in the navigation bar instead of as the
// alert's positive button.
private func aygFiltersImportUrlController(context: AccountContext, initialUrl: String, importFromLink: @escaping (String) -> Void) -> ViewController {
    let statePromise = ValuePromise(initialUrl, ignoreRepeated: true)
    let stateValue = Atomic(value: initialUrl)

    var dismissImpl: (() -> Void)?

    let arguments = AYGFiltersImportUrlArguments(updateUrl: { text in
        statePromise.set(stateValue.modify({ _ in text }))
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> map { presentationData, url -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let rightNavigationButton = ItemListNavigationButton(content: .text(aygString("FiltersImportAction")), style: .bold, enabled: true, action: {
            dismissImpl?()
            importFromLink(url)
        })

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(aygString("FiltersImportURL")),
            leftNavigationButton: nil,
            rightNavigationButton: rightNavigationButton,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: [AYGFiltersImportUrlEntry.url(url)],
            style: .blocks,
            animateChanges: false
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    dismissImpl = { [weak controller] in
        let _ = controller?.navigationController?.popViewController(animated: true)
    }
    return controller
}

// MARK: - Filter list controller

// `dialogId` is the dialog this list belongs to, nil for Shared Filters.
// `chooseFor` turns the screen into Android's choose mode: it is always the
// shared list, its `+` and exclude buttons are hidden, and picking a filter —
// by tapping one, or by selecting several and confirming — excludes it from
// that dialog.
private func aygFiltersListController(context: AccountContext, model: AYGFiltersModel, dialogId: Int64?, chooseFor: Int64? = nil) -> ViewController {
    var pushImpl: ((ViewController) -> Void)?
    var presentControllerImpl: ((ViewController) -> Void)?
    var dismissImpl: (() -> Void)?

    let initialSelection = AYGFiltersListSelection(kind: nil, ids: [])
    let selectionPromise = ValuePromise(initialSelection, ignoreRepeated: true)
    let selectionValue = Atomic(value: initialSelection)
    let updateSelection: ((AYGFiltersListSelection) -> AYGFiltersListSelection) -> Void = { f in
        selectionPromise.set(selectionValue.modify(f))
    }

    // `setSelectionState`: the first selection decides the kind, and a row of
    // the other kind is ignored until the selection is empty again.
    let setSelectionState: (UUID, AYGFiltersSelectionKind, Bool) -> Void = { id, kind, selected in
        updateSelection { current in
            var current = current
            if !current.isActive {
                current.kind = kind
            } else if current.kind != kind {
                return current
            }
            if selected {
                current.ids.insert(id)
            } else {
                current.ids.remove(id)
            }
            if current.ids.isEmpty {
                current.kind = nil
            }
            return current
        }
    }

    let toggleSelection: (UUID, AYGFiltersSelectionKind) -> Void = { id, kind in
        let isSelected = selectionValue.with { $0.ids.contains(id) }
        setSelectionState(id, kind, !isSelected)
    }

    let clearSelection: () -> Void = {
        updateSelection { _ in
            return AYGFiltersListSelection(kind: nil, ids: [])
        }
    }

    // Android's RegexFilterPopup: Edit, Disable/Enable, a gap, then a red Delete.
    let openFilterMenu: (UUID, Bool) -> Void = { id, isExclusion in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        guard let filter = model.current.filters.first(where: { $0.id == id }) else {
            return
        }

        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = []

        // An exclusion only offers Delete — it is a shared filter seen from a
        // dialog, so editing it there would edit it everywhere.
        if !isExclusion {
            items.append(ActionSheetButtonItem(title: presentationData.strings.Common_Edit, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                pushImpl?(aygRegexFilterEditController(context: context, model: model, dialogId: dialogId, filterId: id))
            }))
            items.append(ActionSheetButtonItem(title: filter.isEnabled ? aygString("AYGFiltersActionDisable") : aygString("AYGFiltersActionEnable"), action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                model.update { current in
                    var current = current
                    if let index = current.filters.firstIndex(where: { $0.id == id }) {
                        current.filters[index].isEnabled = !current.filters[index].isEnabled
                    }
                    return current
                }
            }))
        }
        items.append(ActionSheetButtonItem(title: presentationData.strings.Common_Delete, color: .destructive, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            model.update { current in
                var current = current
                if isExclusion, let dialogId {
                    current.exclusions.removeAll(where: { $0.dialogId == dialogId && $0.filterId == id })
                } else {
                    current.filters.removeAll(where: { $0.id == id })
                    current.exclusions.removeAll(where: { $0.filterId == id })
                }
                return current
            }
        }))

        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(actionSheet)
    }

    // `lambda$createView$0`: the filter chosen in choose mode becomes a
    // `RegexFilterGlobalExclusion` for the dialog that opened this screen.
    let excludeFilters: ([UUID]) -> Void = { ids in
        guard let chooseFor else {
            return
        }
        model.update { current in
            var current = current
            for id in ids where !current.exclusions.contains(where: { $0.dialogId == chooseFor && $0.filterId == id }) {
                current.exclusions.append(AYGFilterExclusion(dialogId: chooseFor, filterId: id))
            }
            return current
        }
        dismissImpl?()
    }

    // `onClick`: a tap toggles the selection while the action mode is up,
    // chooses the filter in choose mode, and otherwise opens the popup.
    let openRow: (UUID, AYGFiltersSelectionKind) -> Void = { id, kind in
        if selectionValue.with({ $0.isActive }) {
            toggleSelection(id, kind)
            return
        }
        if chooseFor != nil {
            excludeFilters([id])
            return
        }
        openFilterMenu(id, kind == .exclusion)
    }

    let arguments = AYGFiltersListArguments(selectFilter: { id in
        openRow(id, .filter)
    }, selectExclusion: { id in
        openRow(id, .exclusion)
    }, longPressFilter: { id in
        toggleSelection(id, .filter)
    }, longPressExclusion: { id in
        toggleSelection(id, .exclusion)
    })

    // One instance each, reused across emissions — see AYGFiltersIconButtonNode.
    let excludeButtonNode = AYGFiltersIconButtonNode()
    let toggleEnabledButtonNode = AYGFiltersIconButtonNode()

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        model.statePromise.get(),
        selectionPromise.get()
    )
    |> map { presentationData, state, selection -> (ItemListControllerState, (ItemListNodeState, Any)) in
        // Android: the shared list is titled "Shared Filters", a dialog's list is
        // titled with the dialog's name, shortened to 20 characters.
        var title: String
        if let dialogId, let peer = state.peers[dialogId] {
            let name = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
            title = name.isEmpty ? "?" : aygShortify(name, 20)
        } else if let dialogId {
            title = "\(dialogId)"
        } else {
            title = aygString("RegexFiltersShared")
        }

        var leftNavigationButton: ItemListNavigationButton?
        var rightNavigationButton: ItemListNavigationButton?
        var secondaryRightNavigationButton: ItemListNavigationButton?

        if selection.isActive {
            // The action mode. Android puts the count where the title was and
            // turns the back arrow into "clear the selection"; iOS says the
            // latter with a Cancel button in the left slot, which also takes the
            // back button out of the way while selecting.
            title = "\(selection.ids.count)"
            leftNavigationButton = ItemListNavigationButton(content: .text(presentationData.strings.Common_Cancel), style: .regular, enabled: true, action: {
                clearSelection()
            })

            let (filters, exclusions) = aygFiltersListFilters(state: state, dialogId: dialogId, chooseFor: chooseFor)

            if chooseFor != nil {
                // `confirmSelectedFilters`, the only action mode button in
                // choose mode.
                rightNavigationButton = ItemListNavigationButton(content: .icon(.done), style: .bold, enabled: true, action: {
                    let ids = filters.filter({ selection.ids.contains($0.id) }).map({ $0.id })
                    excludeFilters(ids)
                })
            } else {
                // `getSelectedFiltersEnabledState`: nil when the selection mixes
                // enabled and disabled filters, and then Android hides the
                // toggle rather than guessing which way it should go.
                var uniformEnabled: Bool?
                if selection.kind == .filter {
                    for filter in filters where selection.ids.contains(filter.id) {
                        if let current = uniformEnabled {
                            if current != filter.isEnabled {
                                uniformEnabled = nil
                                break
                            }
                        } else {
                            uniformEnabled = filter.isEnabled
                        }
                    }
                }

                let deleteAction: () -> Void = {
                    model.update { current in
                        var current = current
                        if selection.kind == .filter {
                            for filter in filters where selection.ids.contains(filter.id) {
                                current.filters.removeAll(where: { $0.id == filter.id })
                                current.exclusions.removeAll(where: { $0.filterId == filter.id })
                            }
                        } else if selection.kind == .exclusion, let dialogId {
                            for filter in exclusions where selection.ids.contains(filter.id) {
                                current.exclusions.removeAll(where: { $0.dialogId == dialogId && $0.filterId == filter.id })
                            }
                        }
                        return current
                    }
                    clearSelection()
                }

                if let uniformEnabled {
                    // `msg_noise_off` disables, `msg_noise_on` enables — Android
                    // picks the icon off the state the selection is in now.
                    toggleEnabledButtonNode.update(theme: presentationData.theme, imageName: uniformEnabled ? "AYGFiltersDisable" : "AYGFiltersEnable")
                    rightNavigationButton = ItemListNavigationButton(content: .node(toggleEnabledButtonNode), style: .regular, enabled: true, action: {
                        model.update { current in
                            var current = current
                            for filter in filters where selection.ids.contains(filter.id) {
                                if let index = current.filters.firstIndex(where: { $0.id == filter.id }) {
                                    current.filters[index].isEnabled = !uniformEnabled
                                }
                            }
                            return current
                        }
                        clearSelection()
                    })
                    secondaryRightNavigationButton = ItemListNavigationButton(content: .text(presentationData.strings.Common_Delete), style: .regular, enabled: true, action: deleteAction)
                } else {
                    rightNavigationButton = ItemListNavigationButton(content: .text(presentationData.strings.Common_Delete), style: .regular, enabled: true, action: deleteAction)
                }
            }
        } else if chooseFor != nil {
            // Android hides both buttons while choosing a filter to exclude.
        } else if let dialogId {
            excludeButtonNode.update(theme: presentationData.theme, imageName: "AYGFiltersExclude")
            rightNavigationButton = ItemListNavigationButton(content: .node(excludeButtonNode), style: .regular, enabled: true, action: {
                pushImpl?(aygFiltersListController(context: context, model: model, dialogId: nil, chooseFor: dialogId))
            })
            secondaryRightNavigationButton = ItemListNavigationButton(content: .icon(.add), style: .regular, enabled: true, action: {
                pushImpl?(aygRegexFilterEditController(context: context, model: model, dialogId: dialogId, filterId: nil))
            })
        } else {
            rightNavigationButton = ItemListNavigationButton(content: .icon(.add), style: .regular, enabled: true, action: {
                pushImpl?(aygRegexFilterEditController(context: context, model: model, dialogId: nil, filterId: nil))
            })
        }

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(title),
            leftNavigationButton: leftNavigationButton,
            rightNavigationButton: rightNavigationButton,
            secondaryRightNavigationButton: secondaryRightNavigationButton,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: aygFiltersListEntries(state: state, dialogId: dialogId, chooseFor: chooseFor, selection: selection),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    dismissImpl = { [weak controller] in
        let _ = controller?.navigationController?.popViewController(animated: true)
    }
    return controller
}

// MARK: - Shadow Ban controller

private func aygFiltersShadowBanController(context: AccountContext, model: AYGFiltersModel) -> ViewController {
    var pushImpl: ((ViewController) -> Void)?
    var presentControllerImpl: ((ViewController) -> Void)?

    let arguments = AYGFiltersShadowBanArguments(context: context, openPeer: { dialogId in
        // Android's ShadowBanPopup: a single red Delete.
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Delete, color: .destructive, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    model.update { current in
                        var current = current
                        current.shadowBanned.removeAll(where: { $0 == dialogId })
                        return current
                    }
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(actionSheet)
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        model.statePromise.get()
    )
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let rightNavigationButton = ItemListNavigationButton(content: .icon(.add), style: .regular, enabled: true, action: {
            let selectionController = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.excludeRecent, .doNotSearchMessages, .removeSearchHeader], hasContactSelector: false, title: aygString("FiltersShadowBan")))
            selectionController.peerSelected = { [weak selectionController] peer, _ in
                let dialogId = aygFiltersDialogId(peer.id)
                model.update { current in
                    var current = current
                    current.peers[dialogId] = peer
                    if !current.shadowBanned.contains(dialogId) {
                        current.shadowBanned.append(dialogId)
                    }
                    return current
                }
                // Android calls finishFragment() on the picker; on iOS that is
                // dropping it back out of the navigation stack.
                guard let selectionController, let navigationController = selectionController.navigationController as? NavigationController else {
                    return
                }
                navigationController.setViewControllers(navigationController.viewControllers.filter({ $0 !== selectionController }), animated: true)
            }
            pushImpl?(selectionController)
        })

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(aygString("FiltersShadowBan")),
            leftNavigationButton: nil,
            rightNavigationButton: rightNavigationButton,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: aygFiltersShadowBanEntries(presentationData: presentationData, state: state),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}

// MARK: - The Filters category screen

public func aygFiltersController(context: AccountContext) -> ViewController {
    let model = AYGFiltersModel(context: context)

    var pushImpl: ((ViewController) -> Void)?
    var presentControllerImpl: ((ViewController) -> Void)?
    var replaceWithFiltersListImpl: ((ViewController, Int64) -> Void)?
    var openMenuImpl: (() -> Void)?
    var presentBulletinImpl: ((UndoOverlayContent) -> Void)?
    var resolveImportedPeersImpl: (([(Int64, String)]) -> Void)?

    // `getBlockedPeersFull(true)`. Android refills the list when the switch goes
    // on; refreshing on the screen appearing as well is what keeps the persisted
    // snapshot from going stale after a peer is blocked from somewhere else.
    if model.current.hideFromBlocked {
        model.refreshBlockedPeers()
    }

    let arguments = AYGFiltersArguments(context: context, toggleFiltersEnabled: { value in
        model.update { current in
            var current = current
            current.filtersEnabled = value
            return current
        }
    }, toggleFiltersInChats: { value in
        model.update { current in
            var current = current
            current.sharedFiltersInChats = value
            return current
        }
    }, toggleHideFromBlocked: { value in
        var didEnableFilters = false
        model.update { current in
            var current = current
            current.hideFromBlocked = value
            // Android: switching this on with filters off turns filters on too,
            // and says so.
            if value && !current.filtersEnabled {
                current.filtersEnabled = true
                didEnableFilters = true
            }
            return current
        }
        if value {
            // `getMessagesController().getBlockedPeersFull(true)` — the list has
            // to be there before the switch can hide anything with it.
            model.refreshBlockedPeers()
        }
        if didEnableFilters {
            // `FiltersHideFromBlockedNote`.
            presentBulletinImpl?(.info(title: nil, text: aygFiltersHideFromBlockedNote, timeout: nil, customUndoText: nil))
        }
    }, openSharedFilters: {
        pushImpl?(aygFiltersListController(context: context, model: model, dialogId: nil))
    }, openShadowBan: {
        pushImpl?(aygFiltersShadowBanController(context: context, model: model))
    }, openDialogFilters: { dialogId in
        pushImpl?(aygFiltersListController(context: context, model: model, dialogId: dialogId))
    }, openMenu: {
        openMenuImpl?()
    })

    // One instance, reused: ItemListNavigationButtonContent.node compares by
    // identity, so a fresh node per emission rebuilds the bar button every time.
    let moreButtonNode = AYGFiltersMoreButtonNode()

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        model.statePromise.get()
    )
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        moreButtonNode.update(theme: presentationData.theme)

        let rightNavigationButton = ItemListNavigationButton(content: .node(moreButtonNode), style: .regular, enabled: true, action: {
            arguments.openMenu()
        })

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(AYGSettingsCategory.filters.title),
            leftNavigationButton: nil,
            rightNavigationButton: rightNavigationButton,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: aygFiltersEntries(presentationData: presentationData, state: state),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    presentBulletinImpl = { [weak controller] content in
        aygFiltersPresentBulletin(context: context, controller: controller, content: content)
    }
    // `AyuRequestUtils.resolveAllChats`: a backup carries `dialogId -> "@username"`
    // for the dialogs it cannot assume the receiving client knows, and Android
    // resolves them so the imported filters stop showing raw numbers. The
    // resolved peer goes into the display cache under the *backup's* dialog id,
    // not the resolved one: they are the same number when the resolve is right,
    // and keeping the backup's id is what makes the filter's row find it.
    resolveImportedPeersImpl = { peers in
        for (dialogId, username) in peers {
            let name = username.hasPrefix("@") ? String(username.dropFirst()) : username
            if name.isEmpty {
                continue
            }
            let _ = (context.engine.peers.resolvePeerByName(name: name, referrer: nil)
            |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
                switch result {
                case .progress:
                    return .complete()
                case let .result(peer):
                    return .single(peer)
                }
            }
            |> take(1)
            |> deliverOnMainQueue).startStandalone(next: { peer in
                guard let peer else {
                    return
                }
                AYGFiltersManager.shared.update { current in
                    var current = current
                    current.peers[dialogId] = peer
                    return current
                }
            })
        }
    }

    replaceWithFiltersListImpl = { [weak controller] selectionController, dialogId in
        guard let controller, let navigationController = controller.navigationController as? NavigationController else {
            return
        }
        var controllers = navigationController.viewControllers.filter({ $0 !== selectionController })
        controllers.append(aygFiltersListController(context: context, model: model, dialogId: dialogId))
        navigationController.setViewControllers(controllers, animated: true)
    }

    // `AyuFilterUtils.importFilters`: parse, refuse an unreadable or unchanged
    // backup with the bulletin Android uses, and otherwise ask for confirmation
    // in `FiltersImportBottomSheet` before touching anything.
    let importFilters: (String) -> Void = { text in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        guard let changes = aygFiltersPrepareChanges(json: text, state: model.current) else {
            presentBulletinImpl?(aygFiltersErrorContent(aygFiltersToastFailImport))
            return
        }
        if changes.isEmpty {
            presentBulletinImpl?(aygFiltersErrorContent(aygFiltersToastFailNoChanges))
            return
        }

        let sheet = ActionSheetController(presentationData: presentationData)
        sheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: aygString("FiltersSheetTitle"), font: .large),
                ActionSheetTextItem(title: aygFiltersImportSummary(changes)),
                ActionSheetButtonItem(title: aygString("AYGFiltersApplyYes"), color: .accent, font: .bold, action: { [weak sheet] in
                    sheet?.dismissAnimated()
                    model.update { current in
                        return aygFiltersApplyChanges(changes, to: current)
                    }
                    // `AyuRequestUtils.resolveAllChats(peersToBeResolved)`: the
                    // backup names the dialogs it could not assume this client
                    // knows by @username. Resolving them is what turns an
                    // imported filter's row from a raw number into a chat.
                    resolveImportedPeersImpl?(changes.peersToBeResolved)
                    // `FiltersToastSuccess`, raised by `FiltersImportBottomSheet`.
                    presentBulletinImpl?(.succeed(text: aygFiltersToastSuccess, timeout: nil, customUndoText: nil))
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: aygString("AYGFiltersApplyNo"), color: .accent, action: { [weak sheet] in
                    sheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(sheet)
    }

    // `AyuFilterUtils.importFromLink`, including which of the two failure
    // strings goes with which failure: an empty URL or a transport error is
    // `FiltersToastFailFetch`, a response that carried no usable body is
    // `FiltersToastFailImport`. A successful fetch also writes
    // `lastFiltersImportLink`, which is what prefills the field next time.
    let importFromLink: (String) -> Void = { link in
        if link.isEmpty {
            presentBulletinImpl?(aygFiltersErrorContent(aygFiltersToastFailFetch))
            return
        }
        let _ = (aygFiltersFetch(url: link)
        |> deliverOnMainQueue).startStandalone(next: { result in
            guard result.didConnect else {
                presentBulletinImpl?(aygFiltersErrorContent(aygFiltersToastFailFetch))
                return
            }
            guard let body = result.body else {
                presentBulletinImpl?(aygFiltersErrorContent(aygFiltersToastFailImport))
                return
            }
            AYGFiltersManager.shared.update { current in
                var current = current
                current.lastImportLink = link
                return current
            }
            importFilters(body)
        })
    }

    // The action bar's overflow menu: Select Chat / (gap) / Import, Export /
    // (gap) / Clear. iOS has no popup menu here that carries the Android icons,
    // so it is an action sheet in the same order.
    openMenuImpl = {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let state = model.current

        let presentImportSheet: () -> Void = {
            let sheet = ActionSheetController(presentationData: presentationData)
            sheet.setItemGroups([
                ActionSheetItemGroup(items: [
                    ActionSheetTextItem(title: aygString("FiltersImportTitle")),
                    ActionSheetButtonItem(title: aygString("FiltersImportClipboard"), action: { [weak sheet] in
                        sheet?.dismissAnimated()
                        importFilters(UIPasteboard.general.string ?? "")
                    }),
                    ActionSheetButtonItem(title: aygString("FiltersImportURL"), action: { [weak sheet] in
                        sheet?.dismissAnimated()
                        // Android prefills the field with the clipboard when it
                        // looks like a paste link, and with the last link that
                        // worked otherwise.
                        let clipboard = UIPasteboard.general.string ?? ""
                        var initialUrl = clipboard
                        if !clipboard.contains(".txt") && !clipboard.contains("github") && !clipboard.contains("bin") && !clipboard.contains("paste") {
                            initialUrl = model.current.lastImportLink
                        }
                        pushImpl?(aygFiltersImportUrlController(context: context, initialUrl: initialUrl, importFromLink: importFromLink))
                    })
                ]),
                ActionSheetItemGroup(items: [
                    ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak sheet] in
                        sheet?.dismissAnimated()
                    })
                ])
            ])
            presentControllerImpl?(sheet)
        }

        let presentExportSheet: () -> Void = {
            let sheet = ActionSheetController(presentationData: presentationData)
            sheet.setItemGroups([
                ActionSheetItemGroup(items: [
                    ActionSheetTextItem(title: aygString("FiltersExportTitle")),
                    ActionSheetButtonItem(title: aygString("FiltersExportClipboard"), action: { [weak sheet] in
                        sheet?.dismissAnimated()
                        UIPasteboard.general.string = aygFiltersExport(state: model.current)
                        presentBulletinImpl?(.copy(text: presentationData.strings.Conversation_TextCopied))
                    }),
                    ActionSheetButtonItem(title: aygString("FiltersExportURL"), action: { [weak sheet] in
                        sheet?.dismissAnimated()
                        // `AnonymousClass3`: POST the export to dpaste.com, then
                        // copy the created paste's URL — `Location` + ".txt", the
                        // raw view, which is the only form the import side can
                        // read back. dpaste is AyuGram's own choice of host, not
                        // a service invented here, and it is the only network
                        // dependency the feature has.
                        let payload = aygFiltersExport(state: model.current)
                        let _ = (aygFiltersPublish(content: payload)
                        |> deliverOnMainQueue).startStandalone(next: { result in
                            guard result.didConnect else {
                                presentBulletinImpl?(aygFiltersErrorContent(aygFiltersToastFailFetch))
                                return
                            }
                            guard let url = result.url else {
                                presentBulletinImpl?(aygFiltersErrorContent(aygFiltersToastFailPublish))
                                return
                            }
                            UIPasteboard.general.string = url
                            presentBulletinImpl?(.copy(text: presentationData.strings.Conversation_TextCopied))
                        })
                    })
                ]),
                ActionSheetItemGroup(items: [
                    ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak sheet] in
                        sheet?.dismissAnimated()
                    })
                ])
            ])
            presentControllerImpl?(sheet)
        }

        let presentClearAlert: () -> Void = {
            let state = model.current
            let unknownFilterIds = state.unknownFilterIds
            let unknownExclusions = state.unknownExclusions

            let clearAll = TextAlertAction(type: .destructiveAction, title: aygString("FiltersClearPopupActionText"), action: {
                model.update { current in
                    var current = current
                    current.filters.removeAll()
                    current.exclusions.removeAll()
                    return current
                }
            })
            let cancel = TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {})

            // Android's neutral button, which only appears when there is
            // something it could clear: filters and exclusions whose dialog this
            // client cannot resolve. An import is what usually brings them in.
            if unknownFilterIds.isEmpty && unknownExclusions.isEmpty {
                presentControllerImpl?(textAlertController(context: context, title: aygString("FiltersClearPopupTitle"), text: aygString("FiltersClearPopupText"), actions: [cancel, clearAll]))
                return
            }

            let clearUnknown = TextAlertAction(type: .genericAction, title: aygString("FiltersClearPopupAltActionText"), action: {
                model.update { current in
                    var current = current
                    for id in unknownFilterIds {
                        current.filters.removeAll(where: { $0.id == id })
                    }
                    for exclusion in unknownExclusions {
                        current.exclusions.removeAll(where: { $0.dialogId == exclusion.dialogId && $0.filterId == exclusion.filterId })
                    }
                    return current
                }
            })
            presentControllerImpl?(textAlertController(context: context, title: aygString("FiltersClearPopupTitle"), text: aygString("FiltersClearPopupText"), actions: [clearAll, clearUnknown, cancel], actionLayout: .vertical))
        }

        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = []
        items.append(ActionSheetButtonItem(title: aygString("FiltersMenuSelectChat"), action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            let selectionController = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.excludeRecent, .doNotSearchMessages, .removeSearchHeader], hasContactSelector: false, title: aygString("FiltersMenuSelectChat")))
            selectionController.peerSelected = { [weak selectionController] peer, _ in
                let dialogId = aygFiltersDialogId(peer.id)
                model.update { current in
                    var current = current
                    current.peers[dialogId] = peer
                    return current
                }
                if let selectionController {
                    replaceWithFiltersListImpl?(selectionController, dialogId)
                }
            }
            pushImpl?(selectionController)
        }))
        items.append(ActionSheetButtonItem(title: aygString("FiltersMenuImport"), action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            presentImportSheet()
        }))
        // Android hides Export until there is something to export.
        if !state.isEmpty {
            items.append(ActionSheetButtonItem(title: aygString("FiltersMenuExport"), action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                presentExportSheet()
            }))
        }
        items.append(ActionSheetButtonItem(title: aygString("FiltersMenuClear"), color: .destructive, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            presentClearAlert()
        }))

        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(actionSheet)
    }

    return controller
}
