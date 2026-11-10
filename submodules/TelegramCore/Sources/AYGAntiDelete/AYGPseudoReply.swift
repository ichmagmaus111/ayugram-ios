import Foundation
import Postbox

// AYG: replying **to** a deleted message.
//
// A port of AyuGram for Android's `AyuMessageUtils.prependPseudoReply`. A message the
// fork kept alive exists only in our own postbox — the server deleted its copy — so a
// real reply is impossible: `reply_to_msg_id` pointing at an id the server no longer
// knows either bounces or arrives with an empty quote for everyone.
//
// AyuGram's answer is to not reply at all. The quoted text is folded into the outgoing
// message itself as a blockquote, and the send goes out as an ordinary message. Hence
// "pseudo reply": it reads as a reply, but nothing about it is one.
//
// The shape, straight from Android:
//
//     ┌ **Author Name**          ← bold + a mention link to the author
//     │ the quoted text, ≤100 chars
//     └
//     what you actually typed
//
// The author line is present **only when it says something new**: in a one-to-one chat
// with the very peer being quoted it is omitted, because there is only one person it
// could be. In a group it is there, bold and linked. That asymmetry is Android's
// `isUserDialog(dialogId) && abs(message.dialogId) == abs(dialogId)` test, reproduced
// in `aygPseudoReplyQuote(for:in:)`.

/// What one pending pseudo-reply carries into the send.
public struct AYGPseudoReplyQuote: Equatable {
    /// The quoted message's text, already shortened.
    public let text: String
    /// The author line, or `nil` in a one-to-one chat with that same author.
    public let authorName: String?
    /// Who to link the author line to.
    public let authorPeerId: PeerId?

    public init(text: String, authorName: String?, authorPeerId: PeerId?) {
        self.text = text
        self.authorName = authorName
        self.authorPeerId = authorPeerId
    }
}

/// Android truncates the quote at 100 characters. Counted in UTF-16, as Java does and
/// as message entities do.
private let aygPseudoReplyQuoteLimit = 100

private func aygShortify(_ text: String, limit: Int = aygPseudoReplyQuoteLimit) -> String {
    if text.utf16.count <= limit {
        return text
    }
    let cutoff = text.index(text.startIndex, offsetBy: limit - 1, limitedBy: text.endIndex) ?? text.endIndex
    return String(text[text.startIndex ..< cutoff]) + "…"
}

/// Android uses `ContactsController.formatName(first, last)` for a user and the title
/// for a chat. `EnginePeer.compactDisplayTitle` would be the counterpart here, but it
/// lives in LocalizedPeerData, which depends on TelegramCore — so, as
/// `AYGAntiDeleteHooks` already had to, the two lines are written out instead.
private func aygPseudoReplyAuthorName(_ peer: Peer) -> String? {
    if let user = peer as? TelegramUser {
        let parts = [user.firstName, user.lastName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    } else if let group = peer as? TelegramGroup {
        return group.title.isEmpty ? nil : group.title
    } else if let channel = peer as? TelegramChannel {
        return channel.title.isEmpty ? nil : channel.title
    }
    return nil
}

/// Builds the quote for `message` as seen from the chat `chatPeerId`.
///
/// Returns `nil` when there is nothing to quote — Android bails the same way rather
/// than sending an empty blockquote.
public func aygPseudoReplyQuote(for message: Message, in chatPeerId: PeerId) -> AYGPseudoReplyQuote? {
    var text = message.text
    if text.isEmpty {
        // A media-only deletion archives with a description instead of text.
        if let archived = AntiDeleteManager.shared.getArchivedMessage(peerId: message.id.peerId.toInt64(), messageId: message.id.id) {
            text = archived.text.isEmpty ? (archived.mediaDescription ?? "") : archived.text
        }
    }
    guard !text.isEmpty else {
        return nil
    }

    let author = message.effectiveAuthor
    // One-to-one with the person being quoted: the name would only repeat what the
    // chat already says.
    let isSelfEvidentAuthor = chatPeerId.namespace == Namespaces.Peer.CloudUser && author?.id == chatPeerId
    var authorName: String?
    if !isSelfEvidentAuthor, let author, let name = aygPseudoReplyAuthorName(author) {
        authorName = name
    }

    return AYGPseudoReplyQuote(text: aygShortify(text), authorName: authorName, authorPeerId: author?.id)
}

/// Folds `quote` into the first message that can carry it.
///
/// Only the first: an album is many `EnqueueMessage`s sharing one `localGroupingKey`,
/// and Android dedups on exactly that with its `pseudoReplyGroupIds` map, so the quote
/// appears once above the album rather than on every item.
public func aygApplyPseudoReply(to messages: [EnqueueMessage], quote: AYGPseudoReplyQuote) -> [EnqueueMessage] {
    var result: [EnqueueMessage] = []
    var applied = false

    for message in messages {
        guard !applied, case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets) = message else {
            result.append(message)
            continue
        }

        let namePrefix = quote.authorName.map { $0 + "\n" } ?? ""
        let block = namePrefix + quote.text
        let blockLength = block.utf16.count
        let nameLength = namePrefix.utf16.count

        // A blank message with media still gets the quote — it becomes the caption,
        // which is Android's `canHoldCaption` branch.
        let updatedText: String
        let shift: Int
        if text.isEmpty {
            updatedText = block
            shift = 0
        } else {
            updatedText = block + "\n" + text
            shift = blockLength + 1
        }

        var updatedAttributes: [MessageAttribute] = []
        var entities: [MessageTextEntity] = []
        for attribute in attributes {
            if let textEntities = attribute as? TextEntitiesMessageAttribute {
                // Everything the user typed moves right by the block we just prepended.
                entities = textEntities.entities.map { entity in
                    MessageTextEntity(range: (entity.range.lowerBound + shift) ..< (entity.range.upperBound + shift), type: entity.type)
                }
            } else {
                updatedAttributes.append(attribute)
            }
        }

        if nameLength != 0 {
            entities.append(MessageTextEntity(range: 0 ..< nameLength, type: .Bold))
            if let authorPeerId = quote.authorPeerId {
                entities.append(MessageTextEntity(range: 0 ..< nameLength, type: .TextMention(peerId: authorPeerId)))
            }
        }
        entities.append(MessageTextEntity(range: 0 ..< blockLength, type: .BlockQuote(isCollapsed: false)))
        updatedAttributes.append(TextEntitiesMessageAttribute(entities: entities))

        result.append(.message(
            text: updatedText,
            attributes: updatedAttributes,
            inlineStickers: inlineStickers,
            mediaReference: mediaReference,
            threadId: threadId,
            replyToMessageId: replyToMessageId,
            replyToStoryId: replyToStoryId,
            localGroupingKey: localGroupingKey,
            correlationId: correlationId,
            bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets
        ))
        applied = true
    }

    return applied ? result : messages
}

/// Turns any reply aimed at a deleted message into a pseudo-reply.
///
/// The reply panel is left alone while composing — AyuGram composes with the ordinary
/// one — so the target arrives here on the message itself. Anything replying to a live
/// message passes through untouched.
///
/// `resolveMessage` is injected because this lives below the UI: the caller looks the
/// target up in the history it is already holding.
public func aygConvertRepliesToDeletedMessages(
    _ messages: [EnqueueMessage],
    chatPeerId: PeerId,
    resolveMessage: (MessageId) -> Message?
) -> [EnqueueMessage] {
    guard AntiDeleteManager.shared.isEnabled else {
        return messages
    }

    // The target is the same for every message in an album, so it is resolved once and
    // the quote applied to the first that can carry it.
    var quote: AYGPseudoReplyQuote?
    var strippedReply = false

    var result: [EnqueueMessage] = []
    for message in messages {
        guard case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets) = message,
              let replySubject = replyToMessageId else {
            result.append(message)
            continue
        }
        guard let target = resolveMessage(replySubject.messageId), target.aygIsDeleted else {
            result.append(message)
            continue
        }
        if quote == nil {
            quote = aygPseudoReplyQuote(for: target, in: chatPeerId)
        }
        guard quote != nil else {
            // Nothing quotable. The reply would still arrive empty, so drop it rather
            // than send a reply to an id the server has forgotten.
            result.append(.message(
                text: text,
                attributes: attributes,
                inlineStickers: inlineStickers,
                mediaReference: mediaReference,
                threadId: threadId,
                replyToMessageId: nil,
                replyToStoryId: replyToStoryId,
                localGroupingKey: localGroupingKey,
                correlationId: correlationId,
                bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets
            ))
            strippedReply = true
            continue
        }
        result.append(.message(
            text: text,
            attributes: attributes,
            inlineStickers: inlineStickers,
            mediaReference: mediaReference,
            threadId: threadId,
            replyToMessageId: nil,
            replyToStoryId: replyToStoryId,
            localGroupingKey: localGroupingKey,
            correlationId: correlationId,
            bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets
        ))
        strippedReply = true
    }

    guard strippedReply else {
        return messages
    }
    guard let quote else {
        return result
    }
    return aygApplyPseudoReply(to: result, quote: quote)
}
