// AYG: "Read Exclusion" / "Typing Exclusion" — the two per-chat Ghost Mode entries
// of the AyuGram submenu in a peer's "More" menu.
//
// Android's `ActionsPopupWrapper` puts each behind a chevron that slides a second
// page into the same popup, holding three mutually exclusive rows built by
// `openDetail(String[], int[]{0, 1, 2}, IntSupplier, IntConsumer)`: each row is an
// `ActionBarMenuSubItem` whose `setChecked` is driven by `updateDetailCheckmarks`,
// so exactly one carries a checkmark at a time. That is a radio group, and one
// section of `ItemListCheckboxItem`s is the same control here.
//
// The three values are `AyuGhostExclusions`' per-dialog int, and the semantics come
// from `AyuState.isGhostReadBlockedFor`:
//
//     int type = AyuGhostExclusions.getReadSettingsType(dialogId);
//     if (type != 0) {
//         return type == 1 || !(sendReadPackets || type == 2);
//     }
//     return !sendReadPackets;
//
//   0  Default      follow the account-level switch
//   1  Never Read   blocked outright, whatever the account-level switch says
//   2  Always Read  never blocked, whatever the account-level switch says
//
// `AYGGhostModeManager` covers 0 and 2 with `readMessages` / `showTyping` — an
// exception that *lifts* suppression — and 1 with `forceHideReadMessages` /
// `forceHideTyping`, which are checked ahead of the account-level guard so they can
// impose it. This screen writes exactly one of those pairs; the other exclusion
// flags belong to other screens and are never touched here.

import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

// AYG: `ReadExclusionMenuText`, `TypingExclusionMenuText`, `ExclusionTitle`,
// `ExclusionUseDefault`, `ExclusionDontRead`, `ExclusionAlwaysRead`,
// `ExclusionDontType` and `ExclusionAlwaysType` from the Android strings, verbatim.
public var aygReadExclusionMenuText: String { aygString("ReadExclusionMenuText") }
public var aygTypingExclusionMenuText: String { aygString("TypingExclusionMenuText") }

private var aygExclusionSectionTitle: String { aygString("ExclusionTitle").uppercased() }
private var aygExclusionUseDefaultText: String { aygString("ExclusionUseDefault") }
private var aygExclusionDontReadText: String { aygString("ExclusionDontRead") }
private var aygExclusionAlwaysReadText: String { aygString("ExclusionAlwaysRead") }
private var aygExclusionDontTypeText: String { aygString("ExclusionDontType") }
private var aygExclusionAlwaysTypeText: String { aygString("ExclusionAlwaysType") }

private var aygReadExclusionInfoText: String { aygString("AYGReadExclusionInfo") }
private var aygTypingExclusionInfoText: String { aygString("AYGTypingExclusionInfo") }

/// Which of the two features a screen edits. One screen, two configurations: the row
/// titles, the screen title and the copy are all that differ.
public enum AYGGhostModeExclusionKind {
    case read
    case typing
}

/// AyuGram's per-dialog exclusion type, as stored by `AyuGhostExclusions`.
public enum AYGGhostModeExclusionState: Int, CaseIterable {
    case useDefault = 0
    case never = 1
    case always = 2
}

private extension AYGGhostModeExclusionKind {
    var title: String {
        switch self {
        case .read: return aygReadExclusionMenuText
        case .typing: return aygTypingExclusionMenuText
        }
    }

    var infoText: String {
        switch self {
        case .read: return aygReadExclusionInfoText
        case .typing: return aygTypingExclusionInfoText
        }
    }

    func rowTitle(_ state: AYGGhostModeExclusionState) -> String {
        switch state {
        case .useDefault:
            return aygExclusionUseDefaultText
        case .never:
            switch self {
            case .read: return aygExclusionDontReadText
            case .typing: return aygExclusionDontTypeText
            }
        case .always:
            switch self {
            case .read: return aygExclusionAlwaysReadText
            case .typing: return aygExclusionAlwaysTypeText
            }
        }
    }

    /// Read the state back out of the pair of flags this screen owns. `force…` is read
    /// first because that is the order `shouldHideReadReceipts` resolves them in.
    func state(in settings: AYGGhostModePeerExceptionSettings) -> AYGGhostModeExclusionState {
        switch self {
        case .read:
            if settings.forceHideReadMessages {
                return .never
            }
            return settings.readMessages ? .always : .useDefault
        case .typing:
            if settings.forceHideTyping {
                return .never
            }
            return settings.showTyping ? .always : .useDefault
        }
    }

    /// Write the state into the pair of flags this screen owns, leaving every other
    /// field of the shared record alone. Exactly one of the two flags is ever set, so
    /// the resolution order above never has to break a tie.
    func apply(_ state: AYGGhostModeExclusionState, to settings: inout AYGGhostModePeerExceptionSettings) {
        let lift = state == .always
        let impose = state == .never
        switch self {
        case .read:
            settings.readMessages = lift
            settings.forceHideReadMessages = impose
        case .typing:
            settings.showTyping = lift
            settings.forceHideTyping = impose
        }
    }
}

/// An exception that overrides nothing. `AYGGhostModePeerExceptionSettings.default`
/// turns *every* lifting flag on, which is right for "add this whole chat to the
/// exclusions" and wrong here: switching one chat to "Always Read" must not also hand
/// it the user's online status.
///
/// Every field is written out rather than leaning on the init's defaults, so adding a
/// flag to the struct fails to compile here instead of quietly falling outside the
/// "overrides nothing" test below.
private let aygNeutralExclusionSettings = AYGGhostModePeerExceptionSettings(
    readMessages: false,
    readStories: false,
    showOnlineStatus: false,
    showTyping: false,
    disableForceOffline: false,
    readOnAction: false,
    hiddenActivityKinds: nil,
    forceHideReadMessages: false,
    forceHideTyping: false
)

/// Whether the shared record is still carrying anything.
///
/// This is the synthesized `==` over *all* stored properties, so the two `force…`
/// flags count: a chat left on "Never Read" is not neutral and its record survives,
/// even though every lifting flag on it is false.
private func aygExclusionOverridesNothing(_ settings: AYGGhostModePeerExceptionSettings) -> Bool {
    return settings == aygNeutralExclusionSettings
}

/// The exclusion type in force for this chat and feature.
public func aygGhostModeExclusionState(peerId: EnginePeer.Id, kind: AYGGhostModeExclusionKind) -> AYGGhostModeExclusionState {
    guard let settings = AYGGhostModeManager.shared.exclusionSettings(for: peerId.toInt64()) else {
        return .useDefault
    }
    return kind.state(in: settings)
}

private func aygSetGhostModeExclusion(peerId: EnginePeer.Id, kind: AYGGhostModeExclusionKind, state: AYGGhostModeExclusionState) {
    let key = peerId.toInt64()
    let manager = AYGGhostModeManager.shared

    guard manager.exclusionSettings(for: key) != nil else {
        guard state != .useDefault else {
            // Nothing stored and nothing to store: "Default" is the absence of a record.
            return
        }
        var settings = aygNeutralExclusionSettings
        kind.apply(state, to: &settings)
        manager.addExclusion(key, settings: settings)
        return
    }

    manager.updateExclusionSettings(for: key) { settings in
        kind.apply(state, to: &settings)
    }

    // The other screen may still be overriding its own feature; only drop the shared
    // record once nothing on it is set.
    if let updated = manager.exclusionSettings(for: key), aygExclusionOverridesNothing(updated) {
        manager.removeExclusion(key)
    }
}

private enum AYGGhostModeExclusionSection: Int32 {
    case options
}

private enum AYGGhostModeExclusionEntry: ItemListNodeEntry {
    case header(String)
    case option(AYGGhostModeExclusionState, String, Bool)
    case info(String)

    var section: ItemListSectionId {
        return AYGGhostModeExclusionSection.options.rawValue
    }

    var stableId: Int32 {
        switch self {
        case .header: return 0
        case let .option(state, _, _): return 1 + Int32(state.rawValue)
        case .info: return 1 + Int32(AYGGhostModeExclusionState.allCases.count)
        }
    }

    static func <(lhs: AYGGhostModeExclusionEntry, rhs: AYGGhostModeExclusionEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        guard let arguments = arguments as? AYGGhostModeExclusionArguments else {
            preconditionFailure()
        }
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .option(state, text, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: text, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.select(state)
            })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private final class AYGGhostModeExclusionArguments {
    let select: (AYGGhostModeExclusionState) -> Void

    init(select: @escaping (AYGGhostModeExclusionState) -> Void) {
        self.select = select
    }
}

private func aygGhostModeExclusionEntries(kind: AYGGhostModeExclusionKind, state: AYGGhostModeExclusionState) -> [AYGGhostModeExclusionEntry] {
    var entries: [AYGGhostModeExclusionEntry] = [.header(aygExclusionSectionTitle)]
    // `allCases` is declaration order, which is Android's 0/1/2 order.
    for option in AYGGhostModeExclusionState.allCases {
        entries.append(.option(option, kind.rowTitle(option), option == state))
    }
    entries.append(.info(kind.infoText))
    return entries
}

/// The screen the AyuGram submenu's "Read Exclusion" / "Typing Exclusion" entries push.
///
/// `peerId` is the chat's peer id, keyed as `toInt64()` — the form
/// `AYGGhostModeManager` stores and the form every `shouldHide…(peerId:)` hook site
/// asks with.
public func aygGhostModeExclusionController(context: AccountContext, peerId: EnginePeer.Id, kind: AYGGhostModeExclusionKind) -> ViewController {
    let statePromise = ValuePromise(aygGhostModeExclusionState(peerId: peerId, kind: kind), ignoreRepeated: true)
    let reload: () -> Void = {
        statePromise.set(aygGhostModeExclusionState(peerId: peerId, kind: kind))
    }

    // The other exclusion screen, or the Ghost Mode screen, can drop the shared record
    // while this one is open.
    let observer = NotificationCenter.default.addObserver(forName: AYGGhostModeManager.settingsChangedNotification, object: nil, queue: .main) { _ in
        reload()
    }

    let arguments = AYGGhostModeExclusionArguments(select: { state in
        // Android only calls the consumer when the value actually changes
        // (`if (i != asInt)`), and re-writing the same value here would cost a
        // needless store and a settings-changed broadcast.
        guard state != aygGhostModeExclusionState(peerId: peerId, kind: kind) else {
            return
        }
        aygSetGhostModeExclusion(peerId: peerId, kind: kind, state: state)
        reload()
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, AYGGhostModeExclusionArguments)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(kind.title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: aygGhostModeExclusionEntries(kind: kind, state: state),
            style: .blocks,
            animateChanges: false
        )
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        NotificationCenter.default.removeObserver(observer)
    }

    return ItemListController(context: context, state: signal)
}
