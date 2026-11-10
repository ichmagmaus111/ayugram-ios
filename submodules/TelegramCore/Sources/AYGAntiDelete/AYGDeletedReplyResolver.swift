import Foundation
import Postbox

// AYG: replies whose target has been deleted.
//
// A port of AyuGram for Android's `AyuHistoryHook.fixReplies`. When a message
// replies to one that has since been deleted, the reply header has nothing to
// draw — the server no longer serves the original and Telegram shows an empty
// stub. AyuGram looks the original up in its own archive and attaches it, so the
// quote keeps showing what was actually replied to.
//
// Android's version is bulkier because it also has to resolve users and chats out
// of `MessagesStorage` for messages loaded outside a chat (`buildReplyObjects`,
// `loadCachedReplyMessages`, `normalizeReplyCandidate`). Here the parent message
// already carries the `peers` dictionary its own rendering needs, and the author
// of a deleted reply target is by definition someone already in the conversation,
// so the author resolves out of that with no storage round-trip. What is left is
// Android's `attachReply`: point the reply at a synthesised message.
//
// Works the same in private chats and in groups — the only difference is whose
// name ends up on the quote, which falls out of the archived `authorId`.

/// Attaches the archived original to a reply whose target has been deleted.
///
/// Returns `message` untouched when there is nothing to do, which is the common
/// case — this runs for every message in view, so the early exits matter.
public func aygMessageWithDeletedReplyAttached(_ message: Message) -> Message {
    // `hasAnyKeptMessages` is the wrong question here and was the reason this did
    // nothing: it reports on `deletedMessageIds`, the set of messages *held back* from
    // deletion, while the text this needs lives in the separate archive. Worse, the two
    // are anti-correlated for this feature — a held-back message is still in the postbox,
    // so its reply resolves natively and this function never has to act; the case that
    // needs the archive is exactly the one where nothing was held back.
    guard AntiDeleteManager.shared.isEnabled, AntiDeleteManager.shared.archivedCount != 0 else {
        return message
    }
    guard let replyAttribute = message.attributes.first(where: { $0 is ReplyMessageAttribute }) as? ReplyMessageAttribute else {
        return message
    }
    let replyMessageId = replyAttribute.messageId
    // Already resolved: either the original is still there, or something else
    // filled it in. Android's `findAvailableReplyObject` does the same check first.
    if message.associatedMessages[replyMessageId] != nil {
        return message
    }
    guard let archived = AntiDeleteManager.shared.getArchivedMessage(peerId: replyMessageId.peerId.toInt64(), messageId: replyMessageId.id) else {
        return message
    }

    // A media-only message archives with no text; Android falls back to the same
    // placeholder its own bubble uses.
    var text = archived.text
    if text.isEmpty, let mediaDescription = archived.mediaDescription {
        text = mediaDescription
    }

    var author: Peer?
    if let authorId = archived.authorId {
        author = message.peers[PeerId(authorId)]
    }

    let replyMessage = Message(
        stableId: 0,
        stableVersion: 0,
        id: replyMessageId,
        globallyUniqueId: nil,
        groupingKey: nil,
        groupInfo: nil,
        threadId: archived.threadId,
        timestamp: archived.timestamp,
        flags: [],
        tags: [],
        globalTags: [],
        localTags: [],
        customTags: [],
        forwardInfo: nil,
        author: author,
        text: text,
        attributes: [],
        media: [],
        peers: message.peers,
        associatedMessages: SimpleDictionary<MessageId, Message>(),
        associatedMessageIds: [],
        associatedMedia: [:],
        associatedThreadInfo: nil,
        associatedStories: [:]
    )

    var associatedMessages = message.associatedMessages
    associatedMessages[replyMessageId] = replyMessage

    // `Message.withUpdatedAssociatedMessages` is the one mutator Postbox left
    // internal, so the message is rebuilt here instead of upstream being widened.
    return Message(
        stableId: message.stableId,
        stableVersion: message.stableVersion,
        id: message.id,
        globallyUniqueId: message.globallyUniqueId,
        groupingKey: message.groupingKey,
        groupInfo: message.groupInfo,
        threadId: message.threadId,
        timestamp: message.timestamp,
        flags: message.flags,
        tags: message.tags,
        globalTags: message.globalTags,
        localTags: message.localTags,
        customTags: message.customTags,
        forwardInfo: message.forwardInfo,
        author: message.author,
        text: message.text,
        attributes: message.attributes,
        media: message.media,
        peers: message.peers,
        associatedMessages: associatedMessages,
        associatedMessageIds: message.associatedMessageIds,
        associatedMedia: message.associatedMedia,
        associatedThreadInfo: message.associatedThreadInfo,
        associatedStories: message.associatedStories
    )
}
