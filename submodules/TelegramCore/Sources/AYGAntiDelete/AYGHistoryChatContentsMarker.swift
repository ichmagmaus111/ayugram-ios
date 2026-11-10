import Foundation
import Postbox

// AYG: Edits History and Deleted Messages are real chat screens — a `ChatController`
// on the chat's own peer, fed a custom history (`ChatCustomContentsProtocol`, in
// AccountContext, implemented by `AYGHistoryChatContents` in AyuGramUI) instead of
// the chat's. They borrow the hashtag search's `kind` — the one read-only,
// input-less flavour of custom contents the chat UI knows — and this marker is how
// the chat UI (TelegramUI) tells them apart from a hashtag search where the two
// must differ: the history source on a peer location, the peer's title panels
// stayed hidden, no input panel, the avatar button kept, no read receipts for a
// history that is not the chat's, and a context menu of Copy / Forward only.
//
// TelegramCore because both TelegramUI and AyuGramUI already import it and
// `ChatCustomContentsProtocol` cannot be seen from here; the marker inherits
// nothing and is checked with `as?`.

public enum AYGHistoryChatContentsMode {
    /// The stored pre-edit versions of one message, oldest first.
    case edits
    /// The chat's archived deletions.
    case deleted
}

public protocol AYGHistoryChatContentsMarker: AnyObject {
    var aygHistoryMode: AYGHistoryChatContentsMode { get }

    /// Whether the message is one the postbox still holds (an anti-delete keep)
    /// rather than one this screen synthesised from its archive — only those can
    /// be forwarded.
    func aygIsRealMessage(id: MessageId) -> Bool
}
