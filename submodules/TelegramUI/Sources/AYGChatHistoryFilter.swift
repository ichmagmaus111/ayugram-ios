import Foundation
import Postbox
import TelegramCore
import ChatHistoryEntry

// AYG: where AyuGram's message filters are enforced in the chat.
//
// # Why here
//
// The history pipeline has three places a message could be dropped, and they are
// not interchangeable:
//
//   1. **The postbox view.** `chatHistoryViewForLocation` already threads an
//      `ignoreMessageIds` set all the way down into
//      `AccountViewTracker.aroundMessageHistoryViewForLocation`, which is the
//      genuinely cheapest place to hide a message — the entries never leave
//      Postbox. It is unusable for this feature for two reasons. It wants the
//      ids up front, and a regular expression cannot name the messages it will
//      match before it has seen them; and every change to the set restarts the
//      whole history-view signal, so a scroll that pulls in one new matching
//      message would tear down and reload the view. `MessageHistoryView`'s only
//      public initialiser also drops `anchorIndex`, `maxReadIndex`, the read
//      states and `additionalData`, so rebuilding a filtered one in place is not
//      possible without editing Postbox.
//
//   2. **The entry list, right after `chatHistoryEntriesForView` — this file.**
//      Runs once per history-view update on the history queue, over the window
//      the list actually holds (roughly 50–150 entries), before any
//      `ListViewItem` exists. A dropped entry is never measured, never laid out,
//      cannot be selected, copied, quoted or replied to, and takes no space. It
//      is also the last point at which the album grouping is still visible as
//      one entry, which is what lets a whole album share one verdict the way
//      Android's `GroupedMessages` overload does.
//
//   3. **The item view.** Swiftgram Pro's message filter hooks
//      `ChatMessageItemView.setupItem` and drops the bubble's alpha to 0.2/0.3.
//      That is per-node, re-tested on every reuse, and the message is still
//      there — still selectable, still copyable, still occupying its full
//      height. It also lives in the message *rendering* path, which this change
//      is not allowed to touch.
//
// (2) is the choice. The cost is that the pass re-runs over the whole window on
// every history update rather than once per message ever seen — which is why
// `AYGFilterEngine` memoises the verdict by `stableId`+`stableVersion`, and why
// the whole pass is skipped outright when no filter can match.
//
// # What is *not* filtered here
//
// Only `.MessageEntry` and `.MessageGroupEntry` are candidates. The unread
// separator, the chat/bot info header and the reply-count row are structural and
// stay. Outgoing messages are never filtered — that check lives in the engine,
// which is also where "this is a channel, so filters apply regardless of the
// in-chats switch" is decided.
func aygFilteredChatHistoryEntries(_ entries: [ChatHistoryEntry], accountPeerId: PeerId) -> [ChatHistoryEntry] {
    let engine = AYGFilterEngine.shared
    // One settings read for the whole pass, and the common case — nobody has
    // ever added a filter — costs exactly this much.
    if engine.isInert {
        return entries
    }

    var result: [ChatHistoryEntry] = []
    result.reserveCapacity(entries.count)
    for entry in entries {
        switch entry {
        case let .MessageEntry(message, _, _, _, _, _):
            if engine.isFiltered(message: message, groupMessages: nil, accountPeerId: accountPeerId) {
                continue
            }
        case let .MessageGroupEntry(_, messages, _):
            // An album is one bubble: Android matches the concatenated text of
            // every part against the primary message's dialog and hides all of
            // it or none of it.
            guard let primary = messages.first?.0 else {
                continue
            }
            if engine.isFiltered(message: primary, groupMessages: messages.map({ $0.0 }), accountPeerId: accountPeerId) {
                continue
            }
        default:
            break
        }
        result.append(entry)
    }
    return result
}
