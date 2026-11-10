// AYG: the "AyuGram" row in a peer's "More" menu, and the four-entry submenu
// behind it.
//
// A port of `com.radolyn.ayugram.ui.ActionsPopupWrapper`, which on Android hangs off
// the chat's own action-bar menu rather than the profile. Same four entries, same
// order, same gating, and the nearest glyph in this icon set to each of Android's:
//
//     View Deleted        msg_archive     → Archive         always
//     Read Exclusion      msg_view_file   → Read            not a broadcast channel,
//     Typing Exclusion    msg_edit        → Edit              not Saved Messages
//                                           — both with a trailing chevron
//                                             (Android: msg_arrowright)
//     ─────────────────
//     Clear Deleted       msg_clear       → ClearMessages   always, key_text_RedBold
//
// The two substitutions are explained at their call sites.
//
// Two things Android's wrapper has that are dropped here: its filter entries, which
// belong to a feature the AyuGram screen owns rather than to a peer, and its debug
// "Send Screenshot".
//
// The two exclusion entries open real pushed screens instead of Android's second
// popup page. `ContextController` can push a page (`pushItems` / `popItems`, which
// is what the auto-delete entry above does), but the exclusion pages are settings
// the user comes back to, and every other AyuGram setting in this fork is an
// `ItemListController`.

import Foundation
import UIKit
import Display
import AccountContext
import TelegramCore
import ContextUI
import UndoUI
import PresentationDataUtils
import AyuGramUI

extension PeerInfoScreenNode {
    /// Where the AyuGram row goes: at the end of the menu, but above the trailing run
    /// of destructive entries ("Block User", "Leave Group", …) and above the separator
    /// that introduces them, so it does not trail a block of red.
    private func aygAyuGramMenuInsertionIndex(in items: [ContextMenuItem]) -> Int {
        var index = items.count
        while index > 0, case let .action(action) = items[index - 1], case .destructive = action.textColor {
            index -= 1
        }
        if index == items.count {
            return index
        }
        if index > 0, case .separator = items[index - 1] {
            index -= 1
        }
        return index
    }

    func aygInsertAyuGramMenuItem(into items: inout [ContextMenuItem], chatPeer: EnginePeer) {
        let index = self.aygAyuGramMenuInsertionIndex(in: items)
        // Its own group: everything else in this menu acts on the chat through
        // Telegram, and this one block does not.
        var inserted: [ContextMenuItem] = [self.aygAyuGramMenuItem(chatPeer: chatPeer)]
        if index > 0 {
            inserted.insert(.separator, at: 0)
        }
        items.insert(contentsOf: inserted, at: index)
    }

    private func aygAyuGramMenuItem(chatPeer: EnginePeer) -> ContextMenuItem {
        // The archive is keyed on the *chat's* peer id (`message.id.peerId.toInt64()`
        // in `AYGAntiDeleteHooks`), and so are the Ghost Mode exceptions. For a secret
        // chat that is the secret chat, not the user behind it — `data.peer` would be
        // the wrong one.
        let peerId = chatPeer.id

        // Android: `!ChatObject.isChannelAndNotMegaGroup(chat) && !UserObject.isUserSelf(user)`.
        // Neither exception has anything to answer in a broadcast channel (nothing to
        // read a receipt for, nothing to type into) or in Saved Messages.
        var canSetExclusions = true
        if case let .channel(channel) = chatPeer, case .broadcast = channel.info {
            canSetExclusions = false
        }
        if peerId == self.context.account.peerId {
            canSetExclusions = false
        }

        let strings = self.presentationData.strings

        // The heart. Android's row is
        // `headerItem.lazilyAddSwipeBackItem(R.drawable.msg2_reactions2, null, null, wrapper.swipeBack)`
        // — `msg2_reactions2` is Telegram-Android's heart glyph, the one its Reactions
        // setting uses, and the two nulls mean the row carries the heart and nothing
        // else, no title at all. `Chat/Context Menu/Reactions` (`reactionmenu_24.pdf`)
        // is the same glyph on this side, already drawn at context-menu size. The
        // title stays: an iOS context-menu row is a text row with an icon beside it,
        // and one with no text reads as a rendering failure.
        return .action(ContextMenuActionItem(text: aygAppName, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Reactions"), color: theme.contextMenu.primaryColor)
        }, additionalLeftIcon: { theme in
            // Despite the name this one is drawn against the row's trailing edge —
            // see `ContextControllerActionsListActionItemNode`. It is the chevron.
            return generateTintedImage(image: UIImage(bundleImageName: "Item List/ContextDisclosureArrow"), color: theme.contextMenu.secondaryColor)
        }, action: { [weak self] c, _ in
            guard let self else {
                return
            }
            var subItems: [ContextMenuItem] = []

            subItems.append(.action(ContextMenuActionItem(text: strings.Common_Back, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Back"), color: theme.contextMenu.primaryColor)
            }, iconPosition: .left, action: { c, _ in
                c?.popItems()
            })))
            subItems.append(.separator)

            subItems.append(.action(ContextMenuActionItem(text: aygViewDeletedMenuText, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Archive"), color: theme.contextMenu.primaryColor)
            }, action: { [weak self] _, f in
                f(.dismissWithoutContent)

                guard let self else {
                    return
                }
                // The screen is a real chat now; an empty one would only show the
                // wallpaper, so an empty archive says so in a bulletin instead.
                guard aygHasDeletedMessages(peerId: peerId) else {
                    self.controller?.present(UndoOverlayController(
                        presentationData: self.presentationData,
                        content: .info(title: nil, text: aygDeletedMessagesEmptyText, timeout: nil, customUndoText: nil),
                        elevatedLayout: false,
                        action: { _ in return false }
                    ), in: .current)
                    return
                }
                self.controller?.push(aygDeletedMessagesController(context: self.context, peerId: peerId))
            })))

            if canSetExclusions {
                // Android's `msg_view_file` is a plain open eye. This side's
                // "Chat/Context Menu/Eye" is an eye with a slash through it — the
                // stories "hide my views" glyph — which reads as the opposite of what
                // this row does, so the read-receipt checkmarks stand in for it.
                subItems.append(.action(ContextMenuActionItem(text: aygReadExclusionMenuText, icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Read"), color: theme.contextMenu.primaryColor)
                }, additionalLeftIcon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Item List/ContextDisclosureArrow"), color: theme.contextMenu.secondaryColor)
                }, action: { [weak self] _, f in
                    f(.dismissWithoutContent)

                    guard let self else {
                        return
                    }
                    self.controller?.push(aygGhostModeExclusionController(context: self.context, peerId: peerId, kind: .read))
                })))

                subItems.append(.action(ContextMenuActionItem(text: aygTypingExclusionMenuText, icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Edit"), color: theme.contextMenu.primaryColor)
                }, additionalLeftIcon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Item List/ContextDisclosureArrow"), color: theme.contextMenu.secondaryColor)
                }, action: { [weak self] _, f in
                    f(.dismissWithoutContent)

                    guard let self else {
                        return
                    }
                    self.controller?.push(aygGhostModeExclusionController(context: self.context, peerId: peerId, kind: .typing))
                })))
            }

            subItems.append(.separator)

            // Android's `msg_clear` is a broom, which has no counterpart here;
            // "ClearMessages" (bubbles with a cross) says the same thing in this icon
            // set and is what "Clear History" already uses.
            subItems.append(.action(ContextMenuActionItem(text: aygClearDeletedMenuText, textColor: .destructive, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/ClearMessages"), color: theme.contextMenu.destructiveColor)
            }, action: { [weak self] _, f in
                f(.dismissWithoutContent)

                self?.aygPresentClearDeletedMessagesConfirmation(peerId: peerId)
            })))

            c?.pushItems(items: .single(ContextController.Items(content: .list(subItems))))
        }))
    }

    /// Android puts this behind `AlertsCreator.createSimpleAlert` with the positive
    /// button repainted `key_text_RedBold`; `TextAlertAction(type: .destructiveAction)`
    /// is the same thing here.
    private func aygPresentClearDeletedMessagesConfirmation(peerId: EnginePeer.Id) {
        guard let controller = self.controller else {
            return
        }
        let presentationData = self.presentationData
        let actions: [TextAlertAction] = [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: aygClearDeletedMessagesActionText, action: { [weak self] in
                guard let self else {
                    return
                }
                let count = aygClearDeletedMessages(context: self.context, peerId: peerId)
                self.controller?.present(UndoOverlayController(
                    presentationData: presentationData,
                    content: .info(title: nil, text: aygClearDeletedMessagesResultText(count: count), timeout: nil, customUndoText: nil),
                    elevatedLayout: false,
                    action: { _ in return false }
                ), in: .current)
            })
        ]
        controller.present(textAlertController(
            context: self.context,
            title: aygClearDeletedMessagesTitle,
            text: aygClearDeletedMessagesText,
            actions: actions
        ), in: .window(.root))
    }
}
