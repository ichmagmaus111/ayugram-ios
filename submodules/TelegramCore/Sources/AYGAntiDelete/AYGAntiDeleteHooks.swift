import Foundation
import Postbox

// AYG: Everything the upstream deletion paths need from anti-delete, so those
// files only ever gain one-line calls (CLAUDE.md: prefer adding over editing).
//
// The hook sites are, in the order Telegram reaches them:
//
//   AccountStateManagementUtils   `.DeleteMessages*`, `.UpdateMinAvailableMessage`,
//                                 `.EditMessage`  — the server update stream
//   DeleteMessagesInteractively   you deleting your own messages for everyone
//   DeleteMessages                `_internal_deleteMessages` (last-ditch guard),
//                                 bulk author wipes, secret-chat history clears
//   ProcessSecretChatIncoming…    the peer deleting messages in a secret chat
//   ManagedAutoremoveMessage…     TTL / self-destruct expiry
//   AccountStateManager           suppressing the "messages were deleted" event

/// Short human-readable description of a message's media, stored in the archive
/// so a kept message still reads as something after the media itself is gone.
///
/// Translated here, at capture time, rather than at display: the description is
/// persisted, and reversing a stored English phrase back into a key on the way out
/// would break the moment one of those phrases was reworded. The cost is that an
/// archive captured before a language change keeps the language it was captured in,
/// which is the same trade every stored notification body makes.
func aygAntiDeleteMediaDescription(for message: Message) -> String? {
    var mediaDescription: String?
    for media in message.media {
        switch media {
        case let image as TelegramMediaImage:
            mediaDescription = aygString("AYGMediaPhoto")
            if let largest = image.representations.last {
                mediaDescription = "\(aygString("AYGMediaPhoto")) \(largest.dimensions.width)x\(largest.dimensions.height)"
            }
        case let file as TelegramMediaFile:
            if file.isVideo {
                mediaDescription = aygString("AYGMediaVideo")
            } else if file.isVoice {
                mediaDescription = aygString("AYGMediaVoice")
            } else if file.isInstantVideo {
                mediaDescription = aygString("AYGMediaVideoMessage")
            } else if file.isSticker {
                mediaDescription = aygString("AYGMediaSticker")
            } else {
                mediaDescription = file.fileName ?? aygString("AYGMediaFile")
            }
        case is TelegramMediaContact:
            mediaDescription = aygString("AYGMediaContact")
        case is TelegramMediaMap:
            mediaDescription = aygString("AYGMediaLocation")
        case let poll as TelegramMediaPoll:
            mediaDescription = aygString("AYGMediaPoll", poll.text)
        default:
            break
        }
    }
    return mediaDescription
}

/// The author's display name, resolved at capture time. `EnginePeer.compactDisplayTitle`
/// lives in LocalizedPeerData, which depends on TelegramCore — so the logic is
/// replicated here rather than imported.
private func aygAuthorName(for message: Message) -> String? {
    guard let author = message.author else {
        return nil
    }
    if let user = author as? TelegramUser {
        if let firstName = user.firstName, !firstName.isEmpty {
            return firstName
        } else if let lastName = user.lastName, !lastName.isEmpty {
            return lastName
        }
        return nil
    } else if let group = author as? TelegramGroup {
        return group.title
    } else if let channel = author as? TelegramChannel {
        return channel.title
    }
    return nil
}

/// Archive `message` and mark it deleted in place instead of removing it.
/// Returns false when the message must not be kept (excluded chat, capture off),
/// in which case the caller falls through to the real delete.
@discardableResult
func aygArchiveDeletedMessage(transaction: Transaction, message: Message, globalId: Int32?, mediaBox: MediaBox? = nil) -> Bool {
    guard !AntiDeleteManager.shared.isMessageExcluded(
        chatPeerId: message.id.peerId.toInt64(),
        chatPeer: message.peers[message.id.peerId],
        authorId: message.author?.id.toInt64()
    ) else {
        return false
    }

    let authorUsername: String? = {
        guard let addressName = message.author?.addressName, !addressName.isEmpty else {
            return nil
        }
        return addressName
    }()

    // Copy the media out first: once the delete lands, the resource is gone.
    var archivedMediaFileName: String?
    if let mediaBox = mediaBox {
        archivedMediaFileName = AttachmentArchive.shared.archiveMedia(for: message, mediaBox: mediaBox)
    }

    AntiDeleteManager.shared.archiveMessage(
        globalId: globalId ?? message.id.id,
        peerId: message.id.peerId.toInt64(),
        messageId: message.id.id,
        timestamp: message.timestamp,
        authorId: message.author?.id.toInt64(),
        authorName: aygAuthorName(for: message),
        authorUsername: authorUsername,
        text: message.text,
        forwardAuthorId: message.forwardInfo?.author?.id.toInt64(),
        mediaDescription: aygAntiDeleteMediaDescription(for: message),
        threadId: message.threadId,
        archivedMediaFileName: archivedMediaFileName,
        chatPeer: message.peers[message.id.peerId]
    )
    AntiDeleteManager.shared.markAsDeleted(peerId: message.id.peerId.toInt64(), messageId: message.id.id)
    transaction.updateMessage(message.id, update: { currentMessage in
        var attributes = currentMessage.attributes
        if !attributes.contains(where: { $0 is DeletedMessageAttribute }) {
            attributes.append(DeletedMessageAttribute(deletedAt: Int32(Date().timeIntervalSince1970)))
        }
        let storeForwardInfo = currentMessage.forwardInfo.flatMap(StoreMessageForwardInfo.init)
        return .update(StoreMessage(id: currentMessage.id, customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: attributes, media: currentMessage.media))
    })
    return true
}

/// Already kept. True regardless of the current settings — turning the feature
/// off must not retroactively hard-delete what was already saved.
func aygIsAntiDeleteProtectedMessage(_ message: Message) -> Bool {
    return AntiDeleteManager.shared.isMessageDeleted(peerId: message.id.peerId.toInt64(), messageId: message.id.id)
        || message.attributes.contains(where: { $0 is DeletedMessageAttribute })
}

/// Should this particular deletion be intercepted at all?
func aygShouldKeepDeletedMessageLocally(_ message: Message) -> Bool {
    guard !AntiDeleteManager.shared.isMessageExcluded(
        chatPeerId: message.id.peerId.toInt64(),
        chatPeer: message.peers[message.id.peerId],
        authorId: message.author?.id.toInt64()
    ) else {
        return false
    }

    // "Save in Bot Dialogs" off: skip anything authored by, or sitting in a chat
    // with, a bot.
    if !AntiDeleteManager.shared.showDeletedInBots {
        if let user = message.author as? TelegramUser, user.botInfo != nil {
            return false
        }
        if let peer = message.peers[message.id.peerId] as? TelegramUser, peer.botInfo != nil {
            return false
        }
    }
    // Broadcast channels only — megagroups share the CloudChannel namespace but
    // report `.group`.
    if !AntiDeleteManager.shared.showDeletedInChannels,
       message.id.peerId.namespace == Namespaces.Peer.CloudChannel,
       let channel = message.peers[message.id.peerId] as? TelegramChannel,
       case .broadcast = channel.info {
        return false
    }
    if AntiDeleteManager.shared.shouldCapture {
        return message.id.namespace == Namespaces.Message.Cloud
    }
    if AntiDeleteManager.shared.keepLocallyWhenDeletingForEveryone {
        return message.id.namespace == Namespaces.Message.Cloud && !message.flags.contains(.Incoming)
    }
    return false
}

/// "Save Edits History", including the bot and channel carve-outs. AyuGram's
/// `AyuConfig.saveEditedMessageFor` is the same three checks.
func aygShouldSaveEditHistory(transaction: Transaction, messageId: MessageId, previousMessage: Message) -> Bool {
    guard AntiDeleteManager.shared.displayEditedMessages else {
        return false
    }
    guard AntiDeleteManager.shared.shouldPreserveEditedContentInChat(
        chatPeerId: messageId.peerId.toInt64(),
        chatPeer: previousMessage.peers[messageId.peerId],
        authorId: previousMessage.author?.id.toInt64()
    ) else {
        return false
    }
    if !AntiDeleteManager.shared.showEditedInBots {
        if let user = previousMessage.author as? TelegramUser, user.botInfo != nil {
            return false
        }
        if let peer = transaction.getPeer(messageId.peerId) as? TelegramUser, peer.botInfo != nil {
            return false
        }
    }
    if !AntiDeleteManager.shared.showEditedInChannels,
       messageId.peerId.namespace == Namespaces.Peer.CloudChannel,
       let channel = transaction.getPeer(messageId.peerId) as? TelegramChannel,
       case .broadcast = channel.info {
        return false
    }
    return true
}

/// Drop ids that anti-delete is holding on to. Used by `_internal_deleteMessages`
/// as the last line of defence: history validation, a second getDifference pass
/// and `UpdateMinAvailableMessage` all reach the postbox without passing any of
/// the guards above.
func aygFilterHardDeletableMessageIds(transaction: Transaction, ids: [MessageId]) -> [MessageId] {
    let deferExtensionCloudDelete = AntiDeleteManager.shared.shouldDeferExtensionCloudDelete
    // Fast path. This runs on every single delete Telegram performs, and the
    // per-id `getMessage` below is not free. Nothing can be protected while the
    // deleted-id set is empty: the set and the message attribute are always
    // written together, by `aygArchiveDeletedMessage`, the journal drain and the
    // archive import alike.
    if !deferExtensionCloudDelete && !AntiDeleteManager.shared.hasAnyKeptMessages {
        return ids
    }
    return ids.filter { id in
        if deferExtensionCloudDelete && id.namespace == Namespaces.Message.Cloud {
            return false
        }
        if AntiDeleteManager.shared.isMessageDeleted(peerId: id.peerId.toInt64(), messageId: id.id) {
            return false
        }
        if let message = transaction.getMessage(id), aygIsAntiDeleteProtectedMessage(message) {
            return false
        }
        return true
    }
}

/// Release the anti-delete hold on messages the user is deleting themselves.
///
/// Without this the feature is a one-way door: a kept message carries both the
/// manager's record and the attribute, `_internal_deleteMessages` refuses to
/// remove anything carrying either, and so the user can never get rid of a
/// bubble the other side deleted. Called only from the interactive delete path,
/// where the intent is unambiguous.
func aygForgetKeptMessages(transaction: Transaction, ids: [MessageId]) {
    guard AntiDeleteManager.shared.hasAnyKeptMessages else {
        return
    }
    for id in ids {
        guard let message = transaction.getMessage(id), aygIsAntiDeleteProtectedMessage(message) else {
            continue
        }
        AntiDeleteManager.shared.forgetKeptMessage(peerId: id.peerId.toInt64(), messageId: id.id)
        transaction.updateMessage(id, update: { currentMessage in
            var attributes = currentMessage.attributes
            attributes.removeAll(where: { $0 is DeletedMessageAttribute })
            let storeForwardInfo = currentMessage.forwardInfo.flatMap(StoreMessageForwardInfo.init)
            return .update(StoreMessage(id: currentMessage.id, customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: attributes, media: currentMessage.media))
        })
    }
}

/// Archive an author's messages before a bulk `removeAllMessagesWith(Forward)Author`
/// wipes them. Those admin "delete all from this user" actions go straight
/// through a Postbox primitive that bypasses the guard in
/// `_internal_deleteMessages`, so without this the kept messages would be lost.
func aygArchiveAuthorMessagesBeforeRemoval(transaction: Transaction, mediaBox: MediaBox, peerId: PeerId, authorId: PeerId?, forwardAuthorId: PeerId?, namespace: MessageId.Namespace) {
    guard AntiDeleteManager.shared.shouldCapture else {
        return
    }
    var messagesToArchive: [Message] = []
    transaction.withAllMessages(peerId: peerId, { message in
        guard message.id.namespace == namespace else {
            return true
        }
        if AntiDeleteManager.shared.isMessageDeleted(peerId: message.id.peerId.toInt64(), messageId: message.id.id) {
            return true
        }
        if let authorId = authorId, message.author?.id == authorId {
            messagesToArchive.append(message)
        } else if let forwardAuthorId = forwardAuthorId, message.forwardInfo?.author?.id == forwardAuthorId {
            messagesToArchive.append(message)
        }
        return true
    })
    for message in messagesToArchive {
        aygArchiveDeletedMessage(transaction: transaction, message: message, globalId: nil, mediaBox: mediaBox)
    }
}

/// Same idea for a secret chat's history being cleared: the clear goes through
/// `transaction.clearHistory`, which no guard sees.
func aygArchiveSecretMessagesBeforeHistoryClear(transaction: Transaction, mediaBox: MediaBox, peerId: PeerId, minTimestamp: Int32?, maxTimestamp: Int32?) {
    guard peerId.namespace == Namespaces.Peer.SecretChat, AntiDeleteManager.shared.shouldCapture else {
        return
    }
    var messagesToArchive: [Message] = []
    transaction.withAllMessages(peerId: peerId, { message in
        if let minTimestamp = minTimestamp, message.timestamp < minTimestamp {
            return true
        }
        if let maxTimestamp = maxTimestamp, message.timestamp > maxTimestamp {
            return true
        }
        if AntiDeleteManager.shared.isMessageDeleted(peerId: message.id.peerId.toInt64(), messageId: message.id.id) {
            return true
        }
        messagesToArchive.append(message)
        return true
    })
    for message in messagesToArchive {
        aygArchiveDeletedMessage(transaction: transaction, message: message, globalId: nil, mediaBox: mediaBox)
    }
}
