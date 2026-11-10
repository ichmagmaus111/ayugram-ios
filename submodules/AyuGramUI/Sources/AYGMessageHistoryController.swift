// AYG: "Edits History" — the screen behind the message context menu's "History"
// entry, showing every stored pre-edit version of one message.
//
// Android's `com.radolyn.ayugram.ui.AyuMessageHistory` is a `ChatActivity` clone:
// a real chat fragment with the chat's own action bar, wallpaper, bubbles and date
// separators, showing other messages. That is what this is too — a real
// `ChatController` on the chat's peer, fed the revisions through
// `AYGHistoryChatContents` (the same custom-history door the hashtag search uses)
// instead of the chat's history: the header, theme, wallpaper, blur and bubbles
// are the chat's because they *are* the chat's. The first cut drew the revisions
// as a wallpaper block inside an `ItemListController`, which looked like a
// settings row with a chat painted on it — a strip of list background above the
// wallpaper, rounded corners, no blur under the bar.
//
// Deliberately not ported:
//   * paging — `getRevisions(..., 25)` pages, `EditHistoryManager` keeps a bounded
//     list per message and hands it over whole;
//   * media revisions. `saveOriginalText` archives text only, so a revision that
//     only changed a caption's media has nothing to show.

import Foundation
import UIKit
import Display
import TelegramCore
import AccountContext

// AYG: `EditsHistoryMenuText` from the Android strings.
public var aygEditsHistoryMenuText: String { aygString("EditsHistoryMenuText") }

/// The screen the "History" context-menu entry pushes.
///
/// `isOutgoing` decides which side the bubbles sit on when the message itself is no
/// longer in the postbox; while it is, the revisions take its author and direction.
public func aygMessageHistoryController(context: AccountContext, peerId: EnginePeer.Id, messageId: Int32, isOutgoing: Bool) -> ViewController {
    let contents = AYGHistoryChatContents(context: context, source: .edits(peerId: peerId, messageId: messageId, isOutgoing: isOutgoing))
    // `hideTopPanels`: no topics strip, media player, live location or call bar
    // over a history; the peer's title panels (pinned message, report spam) are
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
