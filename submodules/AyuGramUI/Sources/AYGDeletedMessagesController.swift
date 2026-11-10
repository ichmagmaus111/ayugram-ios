// AYG: "View Deleted" / "Clear Deleted" — the two AntiDelete entries of the
// AyuGram submenu in a peer's "More" menu.
//
// Android's `com.radolyn.ayugram.ui.AyuMessageHistory` opened with a dialog id
// (`loadDeleted`) is a full `ChatActivity` clone: real bubbles, avatars, date
// separators, selection, forwarding. This is the same: a real `ChatController` on
// the chat's peer, fed the archive through `AYGHistoryChatContents` instead of the
// chat's history — the deletions anti-delete kept are the postbox's own messages,
// media, replies, reactions and deleted mark included, and the archive rows the
// postbox no longer has are rebuilt as text bubbles (see the contents' header).
// Copy and Forward are what the message menu offers here; restore and
// jump-to-message stay unported.

import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext

// AYG: `ViewDeletedMenuText`, `ClearDeletedMenuText`, `ClearDeletedMessagesTitle`,
// `ClearDeletedMessagesText` and `ClearDeletedMessagesActionText` from the Android
// strings, verbatim.
public var aygViewDeletedMenuText: String { aygString("ViewDeletedMenuText") }
public var aygClearDeletedMenuText: String { aygString("ClearDeletedMenuText") }
public var aygClearDeletedMessagesTitle: String { aygString("ClearDeletedMessagesTitle") }
public var aygClearDeletedMessagesText: String { aygString("ClearDeletedMessagesText") }
public var aygClearDeletedMessagesActionText: String { aygString("ClearDeletedMessagesActionText") }

/// What "View Deleted" says instead of opening an empty chat.
public var aygDeletedMessagesEmptyText: String { aygString("AYGDeletedMessagesEmpty") }

private var aygDeletedMessagesClearedText: String { aygString("AYGDeletedMessagesCleared") }
private var aygDeletedMessagesNothingToClearText: String { aygString("AYGDeletedMessagesNothingToClear") }

/// Whether the archive holds anything for the chat — the menu shows the empty
/// bulletin rather than pushing an empty chat.
public func aygHasDeletedMessages(peerId: EnginePeer.Id) -> Bool {
    return !AntiDeleteManager.shared.getArchivedMessages(forPeerId: peerId.toInt64()).isEmpty
}

/// Drop every archived deletion belonging to one chat.
///
/// Returns how many entries went, so the caller can tell "cleared" from "there was
/// nothing to clear" in its bulletin.
///
/// Clears the archive **and** takes the kept bubbles out of the chat, which is what
/// Android's `clearDeletedFromDialog` does. The bubbles are ordinary postbox messages
/// held alive by anti-delete, so the hold has to be released first — `_internal_deleteMessages`
/// refuses anything still carrying it, and without this the archive emptied while the
/// messages stayed on screen.
///
/// The files `AttachmentArchive` copied out for these messages are left behind too:
/// it exposes `clear()` for the whole folder and nothing per-entry. They are only
/// reachable through the archive record that just went, so what is left is dead
/// weight in the media folder until the user clears it from the Spy screen.
@discardableResult
public func aygClearDeletedMessages(context: AccountContext, peerId: EnginePeer.Id) -> Int {
    let archived = AntiDeleteManager.shared.getArchivedMessages(forPeerId: peerId.toInt64())
    guard !archived.isEmpty else {
        return 0
    }

    // Release the hold before asking for the delete, or the anti-delete guard in
    // `_internal_deleteMessages` throws the ids straight back out.
    var messageIds: [EngineMessage.Id] = []
    for message in archived {
        AntiDeleteManager.shared.forgetKeptMessage(peerId: message.peerId, messageId: message.messageId)
        messageIds.append(EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Cloud, id: message.messageId))
    }
    let _ = context.engine.messages.deleteMessagesInteractively(messageIds: messageIds, type: .forLocalPeer).startStandalone()

    for message in archived {
        AntiDeleteManager.shared.removeFromArchive(globalId: message.globalId)
    }
    // `removeFromArchive` debounces its own write but posts nothing, so the open
    // screens are told here.
    NotificationCenter.default.post(name: AntiDeleteManager.settingsChangedNotification, object: nil)
    return archived.count
}

/// The bulletin text for a clear that removed `count` entries.
public func aygClearDeletedMessagesResultText(count: Int) -> String {
    return count > 0 ? aygDeletedMessagesClearedText : aygDeletedMessagesNothingToClearText
}

/// The screen the AyuGram submenu's "View Deleted" entry pushes.
///
/// `peerId` is the *chat's* peer id, which is what `AntiDeleteManager` keys the
/// archive on (`message.id.peerId.toInt64()`) — for a secret chat that is the secret
/// chat, not the user behind it.
public func aygDeletedMessagesController(context: AccountContext, peerId: EnginePeer.Id) -> ViewController {
    let contents = AYGHistoryChatContents(context: context, source: .deleted(peerId: peerId))
    // `hideTopPanels`: no topics strip, media player, live location or call bar
    // over the archive; the peer's title panels (pinned message, report spam) are
    // kept out by the marker in `titlePanelForChatPresentationInterfaceState`.
    return context.sharedContext.makeChatController(
        context: context,
        chatLocation: .peer(id: peerId),
        subject: .customChatContents(contents: contents),
        botStart: nil,
        mode: .standard(.default),
        params: ChatControllerParams(hideTopPanels: true)
    )
}
