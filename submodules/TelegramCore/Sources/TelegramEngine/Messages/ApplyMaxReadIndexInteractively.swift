import Foundation
import Postbox
import TelegramApi
import SwiftSignalKit


func _internal_applyMaxReadIndexInteractively(postbox: Postbox, stateManager: AccountStateManager, index: MessageIndex) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        _internal_applyMaxReadIndexInteractively(transaction: transaction, stateManager: stateManager, index: index)
    }
}

/// Applies a read from a caller that has only a message id and no `MessageIndex` - a
/// notification action or a Siri intent.
///
/// Never applies to a secret chat. Reading there is destructive and irreversible: it
/// starts every message's autoremove countdown (below) and tells the other party the
/// messages were seen, for messages the user has not actually opened. These callers act on
/// an id the user never looked at - a notification they replied to, a Siri phrase - so the
/// chat is left unread until it is opened, which is recoverable. That is also what these
/// callers already did in effect: they passed `MessageIndex(id:, timestamp: 0)`, whose zero
/// date matched no message, so a secret chat was never actually read. All that changes is
/// that the invented index no longer becomes the chat's read marker, from where it was
/// pushed as `messages.readEncryptedHistory(max_date: 0)` and rejected.
///
/// For every other peer the read state is id-based: it reads up to `messageId.id` and the
/// index's timestamp is unused, so the id alone is enough. Resolve the stored message's
/// real index anyway when there is one, since it is the honest value.
///
/// Reports whether a read was applied, so a caller that has to answer the user - a Siri
/// intent - can say it did nothing rather than claim success.
func _internal_applyMaxReadMessageIdInteractively(postbox: Postbox, stateManager: AccountStateManager, messageId: MessageId) -> Signal<Bool, NoError> {
    return postbox.transaction { transaction -> Bool in
        guard messageId.peerId.namespace != Namespaces.Peer.SecretChat else {
            return false
        }
        let index = transaction.getMessage(messageId)?.index ?? MessageIndex(id: messageId, timestamp: 0)
        _internal_applyMaxReadIndexInteractively(transaction: transaction, stateManager: stateManager, index: index)
        return true
    }
}

func _internal_applyMaxReadIndexInteractively(transaction: Transaction, stateManager: AccountStateManager, index: MessageIndex) {
    let messageIds = transaction.applyInteractiveReadMaxIndex(index)
    
    if let peer = transaction.getPeer(index.id.peerId), peer.isForumOrMonoForum {
        if let combinedPeerReadState = transaction.getCombinedPeerReadState(peer.id), combinedPeerReadState.count == 0 {
            for item in transaction.getMessageHistoryThreadIndex(peerId: peer.id, limit: 100) {
                guard var data = transaction.getMessageHistoryThreadInfo(peerId: index.id.peerId, threadId: item.threadId)?.data.get(MessageHistoryThreadData.self) else {
                    continue
                }
                guard let messageIndex = transaction.getMessageHistoryThreadTopMessage(peerId: index.id.peerId, threadId: item.threadId, namespaces: Set([Namespaces.Message.Cloud])) else {
                    continue
                }
                if data.incomingUnreadCount != 0 {
                    data.incomingUnreadCount = 0
                    data.isMarkedUnread = false
                    data.maxIncomingReadId = max(messageIndex.id.id, data.maxIncomingReadId)
                    data.maxKnownMessageId = max(data.maxKnownMessageId, messageIndex.id.id)
                    
                    if let entry = StoredMessageHistoryThreadInfo(data) {
                        transaction.setMessageHistoryThreadInfo(peerId: index.id.peerId, threadId: item.threadId, info: entry)
                    }
                }
            }
        }
    }
    
    if index.id.peerId.namespace == Namespaces.Peer.SecretChat {
        let timestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
        for id in messageIds {
            if let message = transaction.getMessage(id) {
                for attribute in message.attributes {
                    if let attribute = attribute as? AutoremoveTimeoutMessageAttribute {
                        if (attribute.countdownBeginTime == nil || attribute.countdownBeginTime == 0) && !message.containsSecretMedia {
                            transaction.updateMessage(message.id, update: { currentMessage in
                                var storeForwardInfo: StoreMessageForwardInfo?
                                if let forwardInfo = currentMessage.forwardInfo {
                                    storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author?.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: forwardInfo.authorSignature, psaType: forwardInfo.psaType, flags: forwardInfo.flags)
                                }
                                let updatedAttributes = currentMessage.attributes.map({ currentAttribute -> MessageAttribute in
                                    if let currentAttribute = currentAttribute as? AutoremoveTimeoutMessageAttribute {
                                        return AutoremoveTimeoutMessageAttribute(timeout: currentAttribute.timeout, countdownBeginTime: timestamp)
                                    } else {
                                        return currentAttribute
                                    }
                                })
                                return .update(StoreMessage(id: currentMessage.id, customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: updatedAttributes, media: currentMessage.media))
                            })
                        }
                        break
                    }
                }
            }
        }
    } else if index.id.peerId.namespace == Namespaces.Peer.CloudUser || index.id.peerId.namespace == Namespaces.Peer.CloudGroup || index.id.peerId.namespace == Namespaces.Peer.CloudChannel {
        stateManager.notifyAppliedIncomingReadMessages([index.id])
    }
}

func applyOutgoingReadMaxIndex(transaction: Transaction, index: MessageIndex, beginCountdownAt timestamp: Int32) {
    let messageIds = transaction.applyOutgoingReadMaxIndex(index)
    if index.id.peerId.namespace == Namespaces.Peer.SecretChat {
        for id in messageIds {
            applySecretOutgoingMessageReadActions(transaction: transaction, id: id, beginCountdownAt: timestamp)
        }
    }
}

func maybeReadSecretOutgoingMessage(transaction: Transaction, index: MessageIndex) {
    guard index.id.peerId.namespace == Namespaces.Peer.SecretChat else {
        assertionFailure()
        return
    }
    guard index.id.namespace == Namespaces.Message.Local else {
        assertionFailure()
        return
    }
    
    guard let combinedState = transaction.getCombinedPeerReadState(index.id.peerId) else {
        return
    }
    
    if combinedState.isOutgoingMessageIndexRead(index) {
        applySecretOutgoingMessageReadActions(transaction: transaction, id: index.id, beginCountdownAt: index.timestamp)
    }
}

func applySecretOutgoingMessageReadActions(transaction: Transaction, id: MessageId, beginCountdownAt timestamp: Int32) {
    guard id.peerId.namespace == Namespaces.Peer.SecretChat else {
        assertionFailure()
        return
    }
    guard id.namespace == Namespaces.Message.Local else {
        assertionFailure()
        return
    }
    
    if let message = transaction.getMessage(id), message.flags.intersection(.IsIncomingMask).isEmpty {
        if message.flags.intersection([.Unsent, .Sending, .Failed]).isEmpty {
            for attribute in message.attributes {
                if let attribute = attribute as? AutoremoveTimeoutMessageAttribute {
                    if (attribute.countdownBeginTime == nil || attribute.countdownBeginTime == 0) && !message.containsSecretMedia {
                        transaction.updateMessage(message.id, update: { currentMessage in
                            var storeForwardInfo: StoreMessageForwardInfo?
                            if let forwardInfo = currentMessage.forwardInfo {
                                storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author?.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: forwardInfo.authorSignature, psaType: forwardInfo.psaType, flags: forwardInfo.flags)
                            }
                            let updatedAttributes = currentMessage.attributes.map({ currentAttribute -> MessageAttribute in
                                if let currentAttribute = currentAttribute as? AutoremoveTimeoutMessageAttribute {
                                    return AutoremoveTimeoutMessageAttribute(timeout: currentAttribute.timeout, countdownBeginTime: timestamp)
                                } else {
                                    return currentAttribute
                                }
                            })
                            return .update(StoreMessage(id: currentMessage.id, customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: updatedAttributes, media: currentMessage.media))
                        })
                    }
                    break
                }
            }
        }
    }
}

func _internal_togglePeerUnreadMarkInteractively(postbox: Postbox, network: Network, viewTracker: AccountViewTracker, peerId: PeerId, setToValue: Bool? = nil) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        _internal_togglePeerUnreadMarkInteractively(transaction: transaction, network: network, viewTracker: viewTracker, peerId: peerId, setToValue: setToValue)
    }
}

func _internal_toggleForumThreadUnreadMarkInteractively(transaction: Transaction, network: Network, viewTracker: AccountViewTracker, peerId: PeerId, threadId: Int64, setToValue: Bool?) {
    guard let peer = transaction.getPeer(peerId) else {
        return
    }
    guard peer.isForumOrMonoForum else {
        return
    }
    guard var data = transaction.getMessageHistoryThreadInfo(peerId: peerId, threadId: threadId)?.data.get(MessageHistoryThreadData.self) else {
        return
    }
    guard let messageIndex = transaction.getMessageHistoryThreadTopMessage(peerId: peerId, threadId: threadId, namespaces: Set([Namespaces.Message.Cloud])) else {
        return
    }
    
    let setToValue = setToValue ?? !(data.incomingUnreadCount != 0 || data.isMarkedUnread)
    
    if setToValue {
        data.isMarkedUnread = true
        if let entry = StoredMessageHistoryThreadInfo(data) {
            transaction.setMessageHistoryThreadInfo(peerId: peerId, threadId: threadId, info: entry)
        }
        
        if peer.isForum {
        } else if peer.isMonoForum {
            if let inputPeer = apiInputPeer(peer), let subPeer = transaction.getPeer(PeerId(threadId)).flatMap(apiInputPeer) {
                let _ = network.request(Api.functions.messages.markDialogUnread(flags: 1 << 0, parentPeer: inputPeer, peer: .inputDialogPeer(.init(peer: subPeer)))).start()
            }
        }
    } else {
        if data.incomingUnreadCount != 0 || data.isMarkedUnread {
            data.incomingUnreadCount = 0
            data.isMarkedUnread = false
            data.maxIncomingReadId = max(messageIndex.id.id, data.maxIncomingReadId)
            data.maxKnownMessageId = max(data.maxKnownMessageId, messageIndex.id.id)
            
            if let entry = StoredMessageHistoryThreadInfo(data) {
                transaction.setMessageHistoryThreadInfo(peerId: peerId, threadId: threadId, info: entry)
            }
            
            if peer.isForum {
                if let inputPeer = apiInputPeer(peer) {
                    let _ = network.request(Api.functions.messages.readDiscussion(peer: inputPeer, msgId: Int32(clamping: threadId), readMaxId: messageIndex.id.id)).start()
                }
            } else if peer.isMonoForum {
                if let inputPeer = apiInputPeer(peer), let subPeer = transaction.getPeer(PeerId(threadId)).flatMap(apiInputPeer) {
                    let _ = network.request(Api.functions.messages.readSavedHistory(parentPeer: inputPeer, peer: subPeer, maxId: messageIndex.id.id)).start()
                }
            }
        }
    }
}

func _internal_markForumThreadAsReadInteractively(transaction: Transaction, network: Network, viewTracker: AccountViewTracker, peerId: PeerId, threadId: Int64) {
    guard let peer = transaction.getPeer(peerId) else {
        return
    }
    guard peer.isForumOrMonoForum else {
        return
    }
    guard var data = transaction.getMessageHistoryThreadInfo(peerId: peerId, threadId: threadId)?.data.get(MessageHistoryThreadData.self) else {
        return
    }
    guard let messageIndex = transaction.getMessageHistoryThreadTopMessage(peerId: peerId, threadId: threadId, namespaces: Set([Namespaces.Message.Cloud])) else {
        return
    }
    if data.incomingUnreadCount != 0 {
        data.incomingUnreadCount = 0
        data.isMarkedUnread = false
        data.maxIncomingReadId = max(messageIndex.id.id, data.maxIncomingReadId)
        data.maxKnownMessageId = max(data.maxKnownMessageId, messageIndex.id.id)
        
        if let entry = StoredMessageHistoryThreadInfo(data) {
            transaction.setMessageHistoryThreadInfo(peerId: peerId, threadId: threadId, info: entry)
        }
        
        if peer.isForum {
            if let inputPeer = apiInputPeer(peer) {
                let _ = network.request(Api.functions.messages.readDiscussion(peer: inputPeer, msgId: Int32(clamping: threadId), readMaxId: messageIndex.id.id)).start()
            }
        } else if peer.isMonoForum {
            if let inputPeer = apiInputPeer(peer), let subPeer = transaction.getPeer(PeerId(threadId)).flatMap(apiInputPeer) {
                let _ = network.request(Api.functions.messages.readSavedHistory(parentPeer: inputPeer, peer: subPeer, maxId: messageIndex.id.id)).start()
            }
        }
    }
}

func _internal_togglePeerUnreadMarkInteractively(transaction: Transaction, network: Network, viewTracker: AccountViewTracker, peerId: PeerId, setToValue: Bool? = nil) {
    guard let peer = transaction.getPeer(peerId) else {
        return
    }
    
    var displayAsRegularChat: Bool = false
    if let channel = peer as? TelegramChannel, channel.flags.contains(.displayForumAsTabs) {
        displayAsRegularChat = true
    } else if let cachedData = transaction.getPeerCachedData(peerId: peerId) as? CachedChannelData {
        displayAsRegularChat = cachedData.viewForumAsMessages.knownValue ?? false
    }
    
    if peer.isForumOrMonoForum, !displayAsRegularChat {
        for item in transaction.getMessageHistoryThreadIndex(peerId: peerId, limit: 20) {
            guard var data = transaction.getMessageHistoryThreadInfo(peerId: peerId, threadId: item.threadId)?.data.get(MessageHistoryThreadData.self) else {
                continue
            }
            guard let messageIndex = transaction.getMessageHistoryThreadTopMessage(peerId: peerId, threadId: item.threadId, namespaces: Set([Namespaces.Message.Cloud])) else {
                continue
            }
            if data.incomingUnreadCount != 0 {
                data.incomingUnreadCount = 0
                data.isMarkedUnread = false
                data.maxIncomingReadId = max(messageIndex.id.id, data.maxIncomingReadId)
                data.maxKnownMessageId = max(data.maxKnownMessageId, messageIndex.id.id)
                
                if let entry = StoredMessageHistoryThreadInfo(data) {
                    transaction.setMessageHistoryThreadInfo(peerId: peerId, threadId: item.threadId, info: entry)
                }
                
                if peer.isForum {
                    if let inputPeer = apiInputPeer(peer) {
                        let _ = network.request(Api.functions.messages.readDiscussion(peer: inputPeer, msgId: Int32(clamping: item.threadId), readMaxId: messageIndex.id.id)).start()
                    }
                } else if peer.isMonoForum {
                    if let inputPeer = apiInputPeer(peer), let subPeer = transaction.getPeer(PeerId(item.threadId)).flatMap(apiInputPeer) {
                        let _ = network.request(Api.functions.messages.readSavedHistory(parentPeer: inputPeer, peer: subPeer, maxId: messageIndex.id.id)).start()
                    }
                }
            }
        }
    } else {
        let principalNamespace: MessageId.Namespace
        if peerId.namespace == Namespaces.Peer.SecretChat {
            principalNamespace = Namespaces.Message.SecretIncoming
        } else {
            principalNamespace = Namespaces.Message.Cloud
        }
        var hasUnread = false
        if let states = transaction.getPeerReadStates(peerId) {
            for state in states {
                if state.1.isUnread {
                    hasUnread = true
                    break
                }
            }
        }
        
        if !hasUnread && peerId.namespace == Namespaces.Peer.SecretChat {
            let unseenSummary = transaction.getMessageTagSummary(peerId: peerId, threadId: nil, tagMask: .unseenPersonalMessage, namespace: Namespaces.Message.Cloud, customTag: nil)
            let actionSummary = transaction.getPendingMessageActionsSummary(peerId: peerId, type: PendingMessageActionType.consumeUnseenPersonalMessage, namespace: Namespaces.Message.Cloud)
            if (unseenSummary?.count ?? 0) - (actionSummary ?? 0) > 0 {
                hasUnread = true
            }
        }
        
        if hasUnread {
            if setToValue == nil || !(setToValue!) {
                if let index = transaction.getTopPeerMessageIndex(peerId: peerId) {
                    let _ = transaction.applyInteractiveReadMaxIndex(index)
                } else {
                    transaction.applyMarkUnread(peerId: peerId, namespace: principalNamespace, value: false, interactive: true)
                }
                viewTracker.updateMarkAllMentionsSeen(peerId: peerId, threadId: nil)
            }
        } else {
            if setToValue == nil || setToValue! {
                transaction.applyMarkUnread(peerId: peerId, namespace: principalNamespace, value: true, interactive: true)
            }
        }
    }
}

public func clearPeerUnseenPersonalMessagesInteractively(account: Account, peerId: PeerId, threadId: Int64?) -> Signal<Never, NoError> {
    return account.postbox.transaction { transaction -> Void in
        if peerId.namespace == Namespaces.Peer.SecretChat {
            return
        }
        account.viewTracker.updateMarkAllMentionsSeen(peerId: peerId, threadId: threadId)
    }
    |> ignoreValues
}

public func clearPeerUnseenReactionsAndPollVotesInteractively(account: Account, peerId: PeerId, threadId: Int64?) -> Signal<Never, NoError> {
    return account.postbox.transaction { transaction -> Void in
        if peerId.namespace == Namespaces.Peer.SecretChat {
            return
        }
        account.viewTracker.updateMarkAllReactionsAndPollVotesSeen(peerId: peerId, threadId: threadId)
    }
    |> ignoreValues
}

func _internal_markAllChatsAsReadInteractively(transaction: Transaction, network: Network, viewTracker: AccountViewTracker, groupId: PeerGroupId, filterPredicate: ChatListFilterPredicate?) {
    for peerId in transaction.getUnreadChatListPeerIds(groupId: groupId, filterPredicate: filterPredicate, additionalFilter: nil, stopOnFirstMatch: false) {
        _internal_togglePeerUnreadMarkInteractively(transaction: transaction, network: network, viewTracker: viewTracker, peerId: peerId, setToValue: false)
    }
}

// AYG: "Mark as Read" — the context-menu action that exists because Ghost Mode
// suppresses read receipts. Local read state races ahead regardless (the chat has
// to look read to its own owner), so this cannot go through
// `_internal_applyMaxReadIndexInteractively`: that only touches the postbox, and
// the outgoing receipt is exactly the part Ghost Mode blocks. Instead this sends
// the read call to the server directly, up to and including `index`, and records
// the new server watermark so the menu entry disappears afterwards.
//
// Ported from the user's other fork. One thing changed on the way: it keyed the
// Ghost Mode tracking on the bare `peerId.id`, while every hook in this tree keys
// on `peerId.toInt64()`. Keeping the original would have written watermarks that
// `SynchronizePeerReadState` could never match.
private enum AYGExplicitReadReceiptTarget {
    case cloudPeer(Api.InputPeer)
    case cloudChannel(Api.InputChannel)
    case secretChat(Api.InputEncryptedChat)
    case discussion(peer: Api.InputPeer, threadId: Int64)
    case savedHistory(parentPeer: Api.InputPeer, peer: Api.InputPeer)
}

func _internal_aygSendExplicitReadReceipt(account: Account, index: MessageIndex, threadId: Int64?) -> Signal<Never, NoError> {
    return account.postbox.transaction { transaction -> AYGExplicitReadReceiptTarget? in
        guard let peer = transaction.getPeer(index.id.peerId) else {
            return nil
        }

        if let threadId {
            guard let inputPeer = apiInputPeer(peer) else {
                return nil
            }
            if let channel = peer as? TelegramChannel, channel.flags.contains(.isMonoforum) {
                guard let subPeer = transaction.getPeer(PeerId(threadId)).flatMap(apiInputPeer) else {
                    return nil
                }
                return .savedHistory(parentPeer: inputPeer, peer: subPeer)
            } else {
                return .discussion(peer: inputPeer, threadId: threadId)
            }
        }

        if index.id.peerId.namespace == Namespaces.Peer.SecretChat {
            guard let inputPeer = apiInputSecretChat(peer) else {
                return nil
            }
            return .secretChat(inputPeer)
        }

        if let inputChannel = apiInputChannel(peer) {
            return .cloudChannel(inputChannel)
        }

        guard let inputPeer = apiInputPeer(peer) else {
            return nil
        }
        return .cloudPeer(inputPeer)
    }
    |> mapToSignal { target -> Signal<Never, NoError> in
        guard let target else {
            return .complete()
        }

        let applied: () -> Void = {
            account.stateManager.notifyAppliedIncomingReadMessages([index.id])
            AYGGhostModeManager.shared.markSyncedToServer(peerId: index.id.peerId.toInt64(), maxMessageId: index.id.id)
        }

        switch target {
        case let .cloudPeer(inputPeer):
            return account.network.request(Api.functions.messages.readHistory(peer: inputPeer, maxId: index.id.id))
            |> map(Optional.init)
            |> `catch` { _ -> Signal<Api.messages.AffectedMessages?, NoError> in
                return .single(nil)
            }
            |> mapToSignal { result -> Signal<Never, NoError> in
                if let result {
                    switch result {
                    case let .affectedMessages(affectedMessagesData):
                        account.stateManager.addUpdateGroups([.updatePts(pts: affectedMessagesData.pts, ptsCount: affectedMessagesData.ptsCount)])
                    }
                    applied()
                }
                return .complete()
            }
        case let .cloudChannel(inputChannel):
            return account.network.request(Api.functions.channels.readHistory(channel: inputChannel, maxId: index.id.id))
            |> map(Optional.init)
            |> `catch` { _ -> Signal<Api.Bool?, NoError> in
                return .single(nil)
            }
            |> mapToSignal { result -> Signal<Never, NoError> in
                if result != nil {
                    applied()
                }
                return .complete()
            }
        case let .secretChat(inputPeer):
            return account.network.request(Api.functions.messages.readEncryptedHistory(peer: inputPeer, maxDate: index.timestamp))
            |> map(Optional.init)
            |> `catch` { _ -> Signal<Api.Bool?, NoError> in
                return .single(nil)
            }
            |> mapToSignal { result -> Signal<Never, NoError> in
                if result != nil {
                    applied()
                }
                return .complete()
            }
        case let .discussion(inputPeer, threadId):
            return account.network.request(Api.functions.messages.readDiscussion(peer: inputPeer, msgId: Int32(clamping: threadId), readMaxId: index.id.id))
            |> map(Optional.init)
            |> `catch` { _ -> Signal<Api.Bool?, NoError> in
                return .single(nil)
            }
            |> mapToSignal { result -> Signal<Never, NoError> in
                if result != nil {
                    applied()
                }
                return .complete()
            }
        case let .savedHistory(parentPeer, peer):
            return account.network.request(Api.functions.messages.readSavedHistory(parentPeer: parentPeer, peer: peer, maxId: index.id.id))
            |> map(Optional.init)
            |> `catch` { _ -> Signal<Api.Bool?, NoError> in
                return .single(nil)
            }
            |> mapToSignal { result -> Signal<Never, NoError> in
                if result != nil {
                    applied()
                }
                return .complete()
            }
        }
    }
}
