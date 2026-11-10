import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import MergeLists
import UndoUI

// AYG: Ghost Mode. A one-for-one port of AyuGram for Android's
// `GhostModePreferencesActivity.fillItems` — same rows, same order, same copy.
//
// The screen owns no settings of its own. Every row reads and writes
// `AYGGhostModeManager`, which is what the read-receipt, presence, typing and story
// hooks in TelegramCore consult — so a switch flipped here takes effect immediately and
// survives relaunch.
//
// The screen keeps exactly two pieces of its own state: which record the account picker
// has selected, and whether the five options are expanded. Both are per-visit.

// AYG: which record is being edited. AyuGram keeps one GhostModeSettings per account
// plus a global one, and the account button in the action bar switches between them —
// the choice is itself persisted, as `AYGGhostModeManager.useGlobalSettings`.
private enum AYGGhostAccountSelection: Equatable {
    case global
    case account(EnginePeer.Id)

    var accountPeerId: EnginePeer.Id? {
        switch self {
        case .global:
            return nil
        case let .account(peerId):
            return peerId
        }
    }
}

private struct AYGGhostScreenState: Equatable {
    var selection: AYGGhostAccountSelection
    var isExpanded: Bool
    var settings: AYGGhostModeSettings
}

/// AyuGram refuses the fifth lock: with all five pinned the master switch would have
/// nothing left to drive, and the only way back would be unlocking one first.
private let aygMaximumLockedOptions = 4

private func aygGhostOptionTitle(_ option: AYGGhostModeOption) -> String {
    switch option {
    case .hideReadReceipts: return aygString("DontReadMessages")
    case .hideStoryViews: return aygString("DontReadStories")
    case .hideOnlineStatus: return aygString("DontSendOnlinePackets")
    case .hideTypingIndicator: return aygString("DontSendUploadProgress")
    case .forceOffline: return aygString("SendOfflinePacketAfterOnline")
    }
}

/// The order the five appear in, which is Android's and is not the enum's declaration
/// order by accident — `AYGGhostModeOption.allCases` is the same list.
private let aygGhostOptions: [AYGGhostModeOption] = [
    .hideReadReceipts,
    .hideStoryViews,
    .hideOnlineStatus,
    .hideTypingIndicator,
    .forceOffline
]

private func aygSendWithoutSoundTitle(_ mode: AYGSendWithoutSoundMode) -> String {
    switch mode {
    case .never: return aygString("SendWithoutSoundByDefaultNever")
    case .inGhostMode: return aygString("SendWithoutSoundByDefaultInGhostMode")
    case .always: return aygString("SendWithoutSoundByDefaultAlways")
    }
}

private let aygSendWithoutSoundOrder: [AYGSendWithoutSoundMode] = [.never, .inGhostMode, .always]

private enum AYGGhostModeSection: Int32 {
    case ghost
    case markRead
    case scheduled
    case withoutSound
    case suggestStory
}

// AYG: the toasts AyuGram raises through `BulletinFactory`. `setGhostMode` shows a
// success bulletin when the master switch goes on and an error-styled one when it
// goes off; `setGlobalOverride` shows an info bulletin, but only when the choice
// actually changes.
private var aygGhostModeEnabledText: String { aygString("GhostModeEnabled") }
private var aygGhostModeDisabledText: String { aygString("GhostModeDisabled") }
private var aygSwitchedToGlobalText: String { aygString("GhostModeSwitchedToGlobalSettings") }
private var aygSwitchedToIndividualText: String { aygString("GhostModeSwitchedToIndividualSettings") }

private func aygPresentBulletin(context: AccountContext, content: UndoOverlayContent, present: ((ViewController) -> Void)?) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    present?(UndoOverlayController(
        presentationData: presentationData,
        content: content,
        elevatedLayout: false,
        action: { _ in return true }
    ))
}

private final class AYGGhostModeArguments {
    let toggleGhostMode: (Bool) -> Void
    let toggleExpanded: () -> Void
    let toggleOption: (AYGGhostModeOption) -> Void
    let toggleOptionLock: (AYGGhostModeOption) -> Void
    let toggleMarkReadAfterAction: (Bool) -> Void
    let toggleUseScheduledMessages: (Bool) -> Void
    let openSendWithoutSound: () -> Void
    let toggleSuggestBeforeStory: (Bool) -> Void
    let openAccountSelector: () -> Void

    init(
        toggleGhostMode: @escaping (Bool) -> Void,
        toggleExpanded: @escaping () -> Void,
        toggleOption: @escaping (AYGGhostModeOption) -> Void,
        toggleOptionLock: @escaping (AYGGhostModeOption) -> Void,
        toggleMarkReadAfterAction: @escaping (Bool) -> Void,
        toggleUseScheduledMessages: @escaping (Bool) -> Void,
        openSendWithoutSound: @escaping () -> Void,
        toggleSuggestBeforeStory: @escaping (Bool) -> Void,
        openAccountSelector: @escaping () -> Void
    ) {
        self.toggleGhostMode = toggleGhostMode
        self.toggleExpanded = toggleExpanded
        self.toggleOption = toggleOption
        self.toggleOptionLock = toggleOptionLock
        self.toggleMarkReadAfterAction = toggleMarkReadAfterAction
        self.toggleUseScheduledMessages = toggleUseScheduledMessages
        self.openSendWithoutSound = openSendWithoutSound
        self.toggleSuggestBeforeStory = toggleSuggestBeforeStory
        self.openAccountSelector = openAccountSelector
    }
}

private enum AYGGhostModeEntry: ItemListNodeEntry {
    case ghostHeader(String)
    case ghostToggle(AYGGhostModeSettings, Bool)
    case ghostFooter(String)
    case markRead(Bool, Bool)
    case markReadFooter(String, Bool)
    case scheduled(Bool)
    case scheduledFooter(String)
    case withoutSound(String)
    case withoutSoundFooter(String)
    case suggestStory(Bool)
    case suggestStoryFooter(String)

    var section: ItemListSectionId {
        switch self {
        case .ghostHeader, .ghostToggle, .ghostFooter:
            return AYGGhostModeSection.ghost.rawValue
        // AYG: collapsed, Ghost Mode and Read on Interact share one block — Android
        // only breaks them apart with the shadow that the expanded checkboxes bring.
        case let .markRead(_, isGrouped), let .markReadFooter(_, isGrouped):
            return isGrouped ? AYGGhostModeSection.ghost.rawValue : AYGGhostModeSection.markRead.rawValue
        case .scheduled, .scheduledFooter:
            return AYGGhostModeSection.scheduled.rawValue
        case .withoutSound, .withoutSoundFooter:
            return AYGGhostModeSection.withoutSound.rawValue
        case .suggestStory, .suggestStoryFooter:
            return AYGGhostModeSection.suggestStory.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .ghostHeader: return 0
        case .ghostToggle: return 1
        case .ghostFooter: return 2
        case .markRead: return 3
        case .markReadFooter: return 4
        case .scheduled: return 5
        case .scheduledFooter: return 6
        case .withoutSound: return 7
        case .withoutSoundFooter: return 8
        case .suggestStory: return 9
        case .suggestStoryFooter: return 10
        }
    }

    static func <(lhs: AYGGhostModeEntry, rhs: AYGGhostModeEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AYGGhostModeArguments
        switch self {
        case let .ghostHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .ghostToggle(settings, isExpanded):
            // The item renders "N/5" and the expand arrow itself, off subItems.
            // A locked option is passed as disabled, which is how Android shows it.
            let subItems = aygGhostOptions.map { option in
                AYGExpandableSwitchItem.SubItem(
                    id: AnyHashable(option.rawValue),
                    title: aygGhostOptionTitle(option),
                    isSelected: settings.isSelected(option),
                    isEnabled: !settings.isLocked(option)
                )
            }
            return AYGExpandableSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: aygString("GhostModeToggle"),
                value: settings.isGhostModeActive,
                isExpanded: isExpanded,
                subItems: subItems,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.toggleGhostMode(value)
                },
                selectAction: {
                    arguments.toggleExpanded()
                },
                subAction: { subItem in
                    if let raw = subItem.id.base as? String, let option = AYGGhostModeOption(rawValue: raw) {
                        arguments.toggleOption(option)
                    }
                },
                subLongPressAction: { subItem in
                    if let raw = subItem.id.base as? String, let option = AYGGhostModeOption(rawValue: raw) {
                        arguments.toggleOptionLock(option)
                    }
                }
            )
        case let .ghostFooter(text), let .scheduledFooter(text),
             let .withoutSoundFooter(text), let .suggestStoryFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .markReadFooter(text, _):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .markRead(value, _):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygString("MarkReadAfterAction"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleMarkReadAfterAction(value)
            })
        case let .scheduled(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygString("UseScheduledMessages"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleUseScheduledMessages(value)
            })
        case let .withoutSound(value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: aygString("SendWithoutSoundByDefault"), label: value, labelStyle: .coloredText(presentationData.theme.list.itemAccentColor), sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.openSendWithoutSound()
            })
        case let .suggestStory(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: aygString("SuggestGhostModeBeforeViewingStory"), value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleSuggestBeforeStory(value)
            })
        }
    }
}

private func aygGhostModeEntries(state: AYGGhostScreenState) -> [AYGGhostModeEntry] {
    let settings = state.settings
    var entries: [AYGGhostModeEntry] = [
        .ghostHeader(aygString("GhostEssentialsHeader").uppercased()),
        .ghostToggle(settings, state.isExpanded)
    ]
    // Expanded, the checkboxes bring their own footer and that ends the block.
    if state.isExpanded {
        entries.append(.ghostFooter(aygString("GhostModeOptionLongTapDescription")))
    }
    entries.append(.markRead(settings.readOnAction, !state.isExpanded))
    entries.append(.markReadFooter(aygString("MarkReadAfterActionDescription"), !state.isExpanded))
    entries.append(.scheduled(settings.useScheduledMessages))
    entries.append(.scheduledFooter(aygString("UseScheduledMessagesDescription")))
    entries.append(.withoutSound(aygSendWithoutSoundTitle(settings.sendWithoutSound)))
    entries.append(.withoutSoundFooter(aygString("SendWithoutSoundByDefaultDescription")))
    entries.append(.suggestStory(settings.suggestGhostModeBeforeStory))
    entries.append(.suggestStoryFooter(aygString("SuggestGhostModeBeforeViewingStoryDescription")))
    return entries
}

// AYG: the Ghost Mode category screen.
public func aygGhostModeController(context: AccountContext) -> ViewController {
    let manager = AYGGhostModeManager.shared

    // The picker starts on whatever the manager is actually using: the global record, or
    // — in per-account mode — this account's, which is the one in force right now.
    let initialSelection: AYGGhostAccountSelection = manager.useGlobalSettings ? .global : .account(context.account.peerId)
    let initialState = AYGGhostScreenState(
        selection: initialSelection,
        isExpanded: false,
        settings: manager.storedSettings(forAccount: initialSelection.accountPeerId)
    )

    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((AYGGhostScreenState) -> AYGGhostScreenState) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }

    /// Write through the manager, then pull the record back. Reading it back rather than
    /// mutating a local copy is what keeps the screen honest: the manager is free to
    /// refuse or adjust a write, and this way the switch shows what was actually stored.
    let updateSettings: ((inout AYGGhostModeSettings) -> Void) -> Void = { f in
        let selection = stateValue.with { $0.selection }
        manager.updateStoredSettings(forAccount: selection.accountPeerId, f)
        let stored = manager.storedSettings(forAccount: selection.accountPeerId)
        updateState { state in
            var state = state
            state.settings = stored
            return state
        }
    }

    var presentControllerImpl: ((ViewController) -> Void)?
    var openAccountSelectorImpl: (() -> Void)?

    let hapticFeedback = HapticFeedback()

    let arguments = AYGGhostModeArguments(toggleGhostMode: { value in
        // Android's master switch drives all five options at once, skipping locked ones.
        updateSettings { settings in
            settings.setGhostMode(value)
        }
        aygPresentBulletin(
            context: context,
            content: value
                ? .succeed(text: aygGhostModeEnabledText, timeout: nil, customUndoText: nil)
                : .info(title: nil, text: aygGhostModeDisabledText, timeout: nil, customUndoText: nil),
            present: presentControllerImpl
        )
    }, toggleExpanded: {
        updateState { state in
            var state = state
            state.isExpanded = !state.isExpanded
            return state
        }
    }, toggleOption: { option in
        updateSettings { settings in
            guard !settings.isLocked(option) else {
                return
            }
            settings.setSelected(!settings.isSelected(option), for: option)
        }
    }, toggleOptionLock: { option in
        // Locking the fifth is refused, as it is on Android: the master switch would then
        // have nothing to drive. Unlocking is always allowed, or a locked option could
        // never be freed.
        let current = stateValue.with { $0.settings }
        if !current.isLocked(option) && current.lockedOptions.count >= aygMaximumLockedOptions {
            hapticFeedback.error()
            return
        }
        updateSettings { settings in
            if settings.lockedOptions.contains(option) {
                settings.lockedOptions.remove(option)
            } else {
                settings.lockedOptions.insert(option)
            }
        }
    }, toggleMarkReadAfterAction: { value in
        updateSettings { settings in
            settings.readOnAction = value
            // Mutually exclusive with Schedule Messages, as in the Android build: one
            // reads the chat the moment you send, the other does not send yet at all.
            if value {
                settings.useScheduledMessages = false
            }
        }
    }, toggleUseScheduledMessages: { value in
        updateSettings { settings in
            settings.useScheduledMessages = value
            if value {
                settings.readOnAction = false
            }
        }
    }, openSendWithoutSound: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = [ActionSheetTextItem(title: aygString("SendWithoutSoundByDefault"))]
        for mode in aygSendWithoutSoundOrder {
            items.append(ActionSheetButtonItem(title: aygSendWithoutSoundTitle(mode), action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                updateSettings { settings in
                    settings.sendWithoutSound = mode
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
    }, toggleSuggestBeforeStory: { value in
        updateSettings { settings in
            settings.suggestGhostModeBeforeStory = value
        }
    }, openAccountSelector: {
        openAccountSelectorImpl?()
    })

    // One instance, reused: ItemListNavigationButtonContent.node compares by identity,
    // so a fresh node per state emission would rebuild the bar button every time.
    let accountButtonNode = AYGAccountSelectorButtonNode()

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        statePromise.get(),
        context.sharedContext.activeAccountsWithInfo
    )
    |> map { presentationData, screenState, accountsAndInfo -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let accounts = accountsAndInfo.accounts

        var selectedPeer: EnginePeer?
        if case let .account(peerId) = screenState.selection {
            selectedPeer = accounts.first(where: { $0.peer.id == peerId })?.peer
        }
        accountButtonNode.update(context: context, theme: presentationData.theme, peer: selectedPeer)

        // Android hides the switcher outright on a single account.
        var rightNavigationButton: ItemListNavigationButton?
        if accounts.count > 1 {
            rightNavigationButton = ItemListNavigationButton(content: .node(accountButtonNode), style: .regular, enabled: true, action: {
                arguments.openAccountSelector()
            })
        }

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(AYGSettingsCategory.ghostMode.title),
            leftNavigationButton: nil,
            rightNavigationButton: rightNavigationButton,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: aygGhostModeEntries(state: screenState),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }

    // AyuGram collapses per-account settings back into the global record as soon as there
    // is only one account left: per-account means nothing then, and leaving the override
    // off would strand whatever that account had configured.
    let _ = (context.sharedContext.activeAccountsWithInfo
    |> take(1)
    |> deliverOnMainQueue).startStandalone(next: { accountsAndInfo in
        guard accountsAndInfo.accounts.count == 1, !manager.useGlobalSettings else {
            return
        }
        manager.adoptAccountSettingsAsGlobal(context.account.peerId)
        updateState { state in
            var state = state
            state.selection = .global
            state.settings = manager.storedSettings(forAccount: nil)
            return state
        }
        aygPresentBulletin(
            context: context,
            content: .info(title: nil, text: aygSwitchedToGlobalText, timeout: nil, customUndoText: nil),
            present: presentControllerImpl
        )
    })

    openAccountSelectorImpl = {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let _ = (context.sharedContext.activeAccountsWithInfo
        |> take(1)
        |> deliverOnMainQueue).startStandalone(next: { accountsAndInfo in
            let selection = stateValue.with { $0.selection }
            let actionSheet = ActionSheetController(presentationData: presentationData)

            // Picking here is not just "show me this record" — it is what decides whether
            // every account shares one set of settings or keeps its own, so it writes
            // `useGlobalSettings` straight through.
            let select: (AYGGhostAccountSelection) -> Void = { newSelection in
                let wasGlobal = manager.useGlobalSettings
                let isGlobal = (newSelection == .global)
                manager.useGlobalSettings = isGlobal
                if wasGlobal != isGlobal {
                    aygPresentBulletin(
                        context: context,
                        content: .info(title: nil, text: isGlobal ? aygSwitchedToGlobalText : aygSwitchedToIndividualText, timeout: nil, customUndoText: nil),
                        present: presentControllerImpl
                    )
                }
                let stored = manager.storedSettings(forAccount: newSelection.accountPeerId)
                updateState { state in
                    var state = state
                    state.selection = newSelection
                    state.settings = stored
                    return state
                }
            }

            var items: [ActionSheetItem] = []
            items.append(ActionSheetCheckboxItem(title: aygString("GhostModeGlobalSettings"), label: aygString("GhostModeGlobalSettingsDescription"), value: selection == .global, action: { [weak actionSheet] _ in
                actionSheet?.dismissAnimated()
                select(.global)
            }))
            for account in accountsAndInfo.accounts {
                let peerId = account.peer.id
                items.append(ActionSheetCheckboxItem(title: account.peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder), label: "", value: selection == .account(peerId), action: { [weak actionSheet] _ in
                    actionSheet?.dismissAnimated()
                    select(.account(peerId))
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
        })
    }
    return controller
}
