import Foundation
import TelegramPresentationData
import AccountContext
import TelegramCore
import SwiftSignalKit
import Display
import TelegramPresentationData
import PresentationDataUtils
import TextFormat
import UndoUI
import ChatInterfaceState
import PremiumUI
import ReactionSelectionNode
import TopMessageReactions
import ChatMessagePaymentAlertController

// AYG: the one enforcement site the server can see.
//
// Every other content-protection gate in the app is local UI, and unlocking it is a
// boolean (see `AYGForwardingManager`). `messages.forwardMessages` is not: forwarding out
// of a `noforwards` chat is refused server-side with `CHAT_FORWARDS_RESTRICTED`, and a
// secret chat has no forward RPC at all. So unlocking the Forward button on its own would
// just produce a failed send.
//
// AyuGram for Android answers this with `AyuForward.intelligentForward`: it splits the
// selection into runs of "can be forwarded" and "cannot", forwards the first kind
// normally, and *re-sends* the second kind as brand-new messages built from the local
// copy of the media (its `AyuForwardStatusLoadingMedia` — "Loading media" — is that
// download step). This is the iOS shape of the same thing; the per-message build lives in
// `Message.aygCopyForwardEnqueueMessage` in TelegramCore so every forward call site can
// reach it.
//
// What is lost versus a real forward: the "Forwarded from" header, the original date, the
// grouping of an album, and reply links. That is inherent — a copy is a new message.
enum AYGForwardEnqueueMessagesResult {
    case messages([EnqueueMessage])
    /// At least one message needs the copy path and cannot be reproduced (a poll, paid
    /// content, a view-once). Telling the user beats sending half a selection.
    case unsupported
}

extension ChatControllerImpl {
    /// Whether this message must be re-sent as a copy rather than forwarded.
    ///
    /// `Message.aygRequiresCopyForward` covers the channel/group `noforwards` bit, the
    /// per-message flag and secret chats. A *private* chat's Restricted Saving lives on
    /// `CachedUserData`, which a `Message` does not carry, so it has to come from the
    /// current chat state — and only when the message actually belongs to this chat.
    func aygMessageNeedsCopyForward(_ message: EngineRawMessage) -> Bool {
        if message.aygRequiresCopyForward {
            return true
        }
        if case let .peer(peerId) = self.chatLocation, peerId == message.id.peerId {
            if self.presentationInterfaceState.myCopyProtectionEnabled {
                return true
            }
            // NOT `presentationInterfaceState.copyProtectionEnabled`: that one is already
            // bypassed by the time it gets here, so it always reads false while the
            // setting is on. The forward path needs the truth, which is on the cached data.
            if let cachedUserData = self.contentData?.state.peerView?.cachedData as? CachedUserData, cachedUserData.aygIsCopyProtectionEnabledIgnoringBypass {
                return true
            }
        }
        return false
    }

    func aygForwardMessagesNeedCopyForward(_ messages: [EngineRawMessage]) -> Bool {
        return messages.contains(where: { self.aygMessageNeedsCopyForward($0) })
    }

    /// Map a selection onto what to actually enqueue: a real `.forward` where one would
    /// be accepted, a rebuilt `.message` where it would not.
    func aygBuildForwardEnqueueMessages(from messages: [EngineRawMessage], options: ChatInterfaceForwardOptionsState?, threadId: Int64?) -> AYGForwardEnqueueMessagesResult {
        let forwardAttributes: [EngineMessage.Attribute] = [
            ForwardOptionsMessageAttribute(hideNames: options?.hideNames == true, hideCaptions: options?.hideCaptions == true)
        ]
        var result: [EnqueueMessage] = []

        for message in messages {
            if self.aygMessageNeedsCopyForward(message) {
                guard AYGForwardingManager.shared.ignoresCopyProtection else {
                    return .unsupported
                }
                if let copyMessage = message.aygCopyForwardEnqueueMessage(threadId: threadId, hideCaptions: options?.hideCaptions == true, localGroupingKey: nil) {
                    result.append(copyMessage)
                } else {
                    return .unsupported
                }
            } else {
                result.append(.forward(source: message.id, threadId: threadId, grouping: .auto, attributes: forwardAttributes, correlationId: nil))
            }
        }

        return .messages(result)
    }

    /// AyuGram's own wording for this case is `UnforwardableContextMenuText` — "Plain
    /// forwarding is not allowed." — which it uses as a context-menu label rather than an
    /// alert. Strings are hardcoded English in this fork.
    func aygPresentUnsupportedCopyForwardAlert(in controller: ViewController?) {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let alert = textAlertController(
            context: self.context,
            title: nil,
            text: "Plain forwarding is not allowed, and this message type cannot be copied.",
            actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]
        )
        if let controller {
            controller.present(alert, in: .window(.root))
        } else {
            self.present(alert, in: .window(.root))
        }
    }

    func forwardMessages(messageIds: [EngineMessage.Id], options: ChatInterfaceForwardOptionsState? = nil, resetCurrent: Bool = false) {
        let _ = (self.context.engine.data.get(EngineDataMap(
            messageIds.map(TelegramEngine.EngineData.Item.Messages.Message.init)
        ))
        |> deliverOnMainQueue).startStandalone(next: { [weak self] messages in
            let sortedMessages = messages.values.compactMap { $0?._asMessage() }.sorted { lhs, rhs in
                return lhs.id < rhs.id
            }
            self?.forwardMessages(messages: sortedMessages, options: options, resetCurrent: resetCurrent)
        })
    }

    func forwardMessages(messages: [EngineRawMessage], options: ChatInterfaceForwardOptionsState? = nil, resetCurrent: Bool) {
        let _ = self.presentVoiceMessageDiscardAlert(action: { [weak self] in
            guard let self else {
                return
            }

            var filter: ChatListNodePeersFilter = [.onlyWriteable, .excludeDisabled, .doNotSearchMessages]
            var hasPublicPolls = false
            var hasPublicQuiz = false
            var hasTodo = false
            for message in messages {
                for media in message.media {
                    if let poll = media as? TelegramMediaPoll, case .public = poll.publicity {
                        hasPublicPolls = true
                        if case .quiz = poll.kind {
                            hasPublicQuiz = true
                        }
                        filter.insert(.excludeChannels)
                    } else if let _ = media as? TelegramMediaTodo {
                        hasTodo = true
                        filter.insert(.excludeChannels)
                    } else if let _ = media as? TelegramMediaPaidContent {
                        filter.insert(.excludeSecretChats)
                    }
                }
            }
            var attemptSelectionImpl: ((EnginePeer, ChatListDisabledPeerReason) -> Void)?
            let controller = self.context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: self.context, updatedPresentationData: self.updatedPresentationData, filter: filter, hasFilters: true, attemptSelection: { peer, _, reason in
                attemptSelectionImpl?(peer, reason)
            }, multipleSelection: true, forwardedMessageIds: self.aygForwardMessagesNeedCopyForward(messages) && AYGForwardingManager.shared.ignoresCopyProtection ? [] : messages.map { $0.id }, selectForumThreads: true))
            let context = self.context
            attemptSelectionImpl = { [weak self, weak controller] peer, reason in
                guard let strongSelf = self, let controller = controller else {
                    return
                }
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                if hasPublicPolls {
                    if case let .channel(channel) = peer, case .broadcast = channel.info {
                        controller.present(textAlertController(context: context, title: nil, text: hasPublicQuiz ? presentationData.strings.Forward_ErrorPublicQuizDisabledInChannels : presentationData.strings.Forward_ErrorPublicPollDisabledInChannels, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                        return
                    }
                } else if hasTodo {
                    if case let .channel(channel) = peer, case .broadcast = channel.info {
                        controller.present(textAlertController(context: context, title: nil, text: presentationData.strings.Forward_ErrorTodoDisabledInChannels, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                        return
                    }
                }
                switch reason {
                case .generic:
                    controller.present(textAlertController(context: context, updatedPresentationData: strongSelf.updatedPresentationData, title: nil, text: presentationData.strings.Forward_ErrorDisabledForChat, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                case .premiumRequired:
                    controller.forEachController { c in
                        if let c = c as? UndoOverlayController {
                            c.dismiss()
                        }
                        return true
                    }
                    
                    var hasAction = false
                    let premiumConfiguration = PremiumConfiguration.with(appConfiguration: strongSelf.context.currentAppConfiguration.with { $0 })
                    if !premiumConfiguration.isPremiumDisabled {
                        hasAction = true
                    }
                    
                    controller.present(UndoOverlayController(presentationData: presentationData, content: .premiumPaywall(title: nil, text: presentationData.strings.Chat_ToastMessagingRestrictedToPremium_Text(peer.compactDisplayTitle).string, customUndoText: hasAction ? presentationData.strings.Chat_ToastMessagingRestrictedToPremium_Action : nil, timeout: nil, linkAction: { _ in
                    }), elevatedLayout: false, animateInAsReplacement: true, action: { [weak controller] action in
                        guard let self, let controller else {
                            return false
                        }
                        if case .undo = action {
                            let premiumController = PremiumIntroScreen(context: self.context, source: .settings)
                            controller.push(premiumController)
                        }
                        return false
                    }), in: .current)
                }
            }
            controller.multiplePeersSelected = { [weak self, weak controller] peers, peerMap, messageText, mode, forwardOptions, _ in
                let peerIds = peers.map { $0.id }
                
                let _ = (context.engine.data.get(
                    EngineDataMap(
                        peerIds.map(TelegramEngine.EngineData.Item.Peer.SendPaidMessageStars.init(id:))
                    ),
                    EngineDataList(
                        peerIds.map(TelegramEngine.EngineData.Item.Peer.RenderedPeer.init(id:))
                    )
                )
                |> deliverOnMainQueue).start(next: { [weak self, weak controller] sendPaidMessageStars, renderedPeers in
                    guard let strongSelf = self else {
                        return
                    }
                    let renderedPeers = renderedPeers.compactMap({ $0 })
                    
                    var count: Int32 = Int32(messages.count)
                    if messageText.string.count > 0 {
                        count += 1
                    }
                    var totalAmount: StarsAmount = .zero
                    var chargingPeers: [EngineRenderedPeer] = []
                    for peer in renderedPeers {
                        if let maybeAmount = sendPaidMessageStars[peer.peerId], let amount = maybeAmount {
                            totalAmount = totalAmount + amount
                            chargingPeers.append(peer)
                        }
                    }
                                        
                    let proceed = { [weak self, weak controller] in
                        guard let strongSelf = self, let strongController = controller else {
                            return
                        }
                        
                        strongController.dismiss()
                        
                        var result: [EnqueueMessage] = []
                        if messageText.string.count > 0 {
                            let inputText = convertMarkdownToAttributes(messageText)
                            for text in breakChatInputText(trimChatInputText(inputText)) {
                                if text.length != 0 {
                                    var attributes: [EngineMessage.Attribute] = []
                                    let entities = generateTextEntities(text.string, enabledTypes: .all, currentEntities: generateChatInputTextEntities(text))
                                    if !entities.isEmpty {
                                        attributes.append(TextEntitiesMessageAttribute(entities: entities))
                                    }
                                    result.append(.message(text: text.string, attributes: attributes, inlineStickers: [:], mediaReference: nil, threadId: strongSelf.chatLocation.threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))
                                }
                            }
                        }
                        
                        // AYG: `.forward` where the server would accept one, a rebuilt copy where it would not.
                        switch strongSelf.aygBuildForwardEnqueueMessages(from: messages, options: forwardOptions, threadId: nil) {
                        case let .messages(builtMessages):
                            result.append(contentsOf: builtMessages)
                        case .unsupported:
                            strongSelf.aygPresentUnsupportedCopyForwardAlert(in: nil)
                            return
                        }
                        
                        let commit: ([EnqueueMessage]) -> Void = { result in
                            guard let strongSelf = self else {
                                return
                            }
                            var result = result
                            
                            strongSelf.updateChatPresentationInterfaceState(animated: false, interactive: true, { $0.updatedInterfaceState({ $0.withoutSelectionState() }).updatedSearch(nil) })
                            
                            var correlationIds: [Int64] = []
                            for i in 0 ..< result.count {
                                let correlationId = Int64.random(in: Int64.min ... Int64.max)
                                correlationIds.append(correlationId)
                                result[i] = result[i].withUpdatedCorrelationId(correlationId)
                            }
                            
                            let targetPeersShouldDivertSignals: [Signal<(EnginePeer, Bool), NoError>] = peers.map { peer -> Signal<(EnginePeer, Bool), NoError> in
                                return strongSelf.shouldDivertMessagesToScheduled(targetPeer: peer, messages: result)
                                |> map { shouldDivert -> (EnginePeer, Bool) in
                                    return (peer, shouldDivert)
                                }
                            }
                            let targetPeersShouldDivert: Signal<[(EnginePeer, Bool)], NoError> = combineLatest(targetPeersShouldDivertSignals)
                            let _ = (targetPeersShouldDivert
                            |> deliverOnMainQueue).startStandalone(next: { targetPeersShouldDivert in
                                guard let strongSelf = self else {
                                    return
                                }
                                
                                var displayConvertingTooltip = false
                                
                                var displayPeers: [EnginePeer] = []
                                for (peer, shouldDivert) in targetPeersShouldDivert {
                                    var peerMessages = result
                                    if shouldDivert {
                                        displayConvertingTooltip = true
                                        peerMessages = peerMessages.map { message -> EnqueueMessage in
                                            return message.withUpdatedAttributes { attributes in
                                                var attributes = attributes
                                                attributes.removeAll(where: { $0 is OutgoingScheduleInfoMessageAttribute })
                                                attributes.append(OutgoingScheduleInfoMessageAttribute(scheduleTime: Int32(Date().timeIntervalSince1970) + 10 * 24 * 60 * 60, repeatPeriod: nil))
                                                return attributes
                                            }
                                        }
                                    }
                                    
                                    if let maybeAmount = sendPaidMessageStars[peer.id], let amount = maybeAmount {
                                        peerMessages = peerMessages.map { message -> EnqueueMessage in
                                            return message.withUpdatedAttributes { attributes in
                                                var attributes = attributes
                                                attributes.append(PaidStarsMessageAttribute(stars: amount, postponeSending: false))
                                                return attributes
                                            }
                                        }
                                    }
                                    
                                    let _ = (enqueueMessages(account: strongSelf.context.account, peerId: peer.id, messages: peerMessages)
                                    |> deliverOnMainQueue).startStandalone(next: { messageIds in
                                        if let strongSelf = self {
                                            let signals: [Signal<Bool, NoError>] = messageIds.compactMap({ id -> Signal<Bool, NoError>? in
                                                guard let id = id else {
                                                    return nil
                                                }
                                                return strongSelf.context.account.pendingMessageManager.pendingMessageStatus(id)
                                                |> mapToSignal { status, _ -> Signal<Bool, NoError> in
                                                    if status != nil {
                                                        return .never()
                                                    } else {
                                                        return .single(true)
                                                    }
                                                }
                                                |> take(1)
                                            })
                                            if strongSelf.shareStatusDisposable == nil {
                                                strongSelf.shareStatusDisposable = MetaDisposable()
                                            }
                                            strongSelf.shareStatusDisposable?.set((combineLatest(signals)
                                            |> deliverOnMainQueue).startStrict())
                                        }
                                    })
                                    
                                    if case let .secretChat(secretPeer) = peer {
                                        if let peer = peerMap[secretPeer.regularPeerId] {
                                            displayPeers.append(peer)
                                        }
                                    } else {
                                        displayPeers.append(peer)
                                    }
                                }
                                
                                let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                                let text: String
                                var savedMessages = false
                                if displayPeers.count == 1, let peerId = displayPeers.first?.id, peerId == strongSelf.context.account.peerId {
                                    text = messages.count == 1 ? presentationData.strings.Conversation_ForwardTooltip_SavedMessages_One : presentationData.strings.Conversation_ForwardTooltip_SavedMessages_Many
                                    savedMessages = true
                                } else {
                                    if displayPeers.count == 1, let peer = displayPeers.first {
                                        var peerName = peer.id == strongSelf.context.account.peerId ? presentationData.strings.DialogList_SavedMessages : peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                                        peerName = peerName.replacingOccurrences(of: "**", with: "")
                                        text = messages.count == 1 ? presentationData.strings.Conversation_ForwardTooltip_Chat_One(peerName).string : presentationData.strings.Conversation_ForwardTooltip_Chat_Many(peerName).string
                                    } else if displayPeers.count == 2, let firstPeer = displayPeers.first, let secondPeer = displayPeers.last {
                                        var firstPeerName = firstPeer.id == strongSelf.context.account.peerId ? presentationData.strings.DialogList_SavedMessages : firstPeer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                                        firstPeerName = firstPeerName.replacingOccurrences(of: "**", with: "")
                                        var secondPeerName = secondPeer.id == strongSelf.context.account.peerId ? presentationData.strings.DialogList_SavedMessages : secondPeer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                                        secondPeerName = secondPeerName.replacingOccurrences(of: "**", with: "")
                                        text = messages.count == 1 ? presentationData.strings.Conversation_ForwardTooltip_TwoChats_One(firstPeerName, secondPeerName).string : presentationData.strings.Conversation_ForwardTooltip_TwoChats_Many(firstPeerName, secondPeerName).string
                                    } else if let peer = displayPeers.first {
                                        var peerName = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                                        peerName = peerName.replacingOccurrences(of: "**", with: "")
                                        text = messages.count == 1 ? presentationData.strings.Conversation_ForwardTooltip_ManyChats_One(peerName, "\(displayPeers.count - 1)").string : presentationData.strings.Conversation_ForwardTooltip_ManyChats_Many(peerName, "\(displayPeers.count - 1)").string
                                    } else {
                                        text = ""
                                    }
                                }
                                
                                let reactionItems: Signal<[ReactionItem], NoError>
                                if savedMessages && messages.count > 0 {
                                    reactionItems = tagMessageReactions(context: strongSelf.context, subPeerId: nil)
                                } else {
                                    reactionItems = .single([])
                                }
                                
                                let _ = (reactionItems
                                |> deliverOnMainQueue).startStandalone(next: { [weak strongSelf] reactionItems in
                                    guard let strongSelf else {
                                        return
                                    }
                                    
                                    strongSelf.present(UndoOverlayController(presentationData: presentationData, content: .forward(savedMessages: savedMessages, text: text), elevatedLayout: false, position: savedMessages && messages.count > 0 ? .top : .bottom, animateInAsReplacement: true, action: { action in
                                        if savedMessages, let self, action == .info {
                                            let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: self.context.account.peerId))
                                                     |> deliverOnMainQueue).start(next: { [weak self] peer in
                                                guard let self, let peer else {
                                                    return
                                                }
                                                guard let navigationController = self.navigationController as? NavigationController else {
                                                    return
                                                }
                                                self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: self.context, chatLocation: .peer(peer), forceOpenChat: true))
                                            })
                                        }
                                        return false
                                    }, additionalView: (savedMessages && messages.count > 0) ? chatShareToSavedMessagesAdditionalView(strongSelf, reactionItems: reactionItems, correlationIds: correlationIds) : nil), in: .current)
                                })
                                
                                if displayConvertingTooltip {
                                }
                            })
                        }
                        
                        switch mode {
                        case .generic:
                            commit(result)
                        case .silent:
                            let transformedMessages = strongSelf.transformEnqueueMessages(result, silentPosting: true)
                            commit(transformedMessages)
                        case .schedule:
                            strongSelf.presentScheduleTimePicker(completion: { [weak self] timeResult in
                                if let strongSelf = self {
                                    let transformedMessages = strongSelf.transformEnqueueMessages(result, silentPosting: timeResult.silentPosting, scheduleTime: timeResult.time, repeatPeriod: timeResult.repeatPeriod)
                                    commit(transformedMessages)
                                }
                            })
                        case .whenOnline:
                            let transformedMessages = strongSelf.transformEnqueueMessages(result, silentPosting: strongSelf.presentationInterfaceState.interfaceState.silentPosting, scheduleTime: scheduleWhenOnlineTimestamp)
                            commit(transformedMessages)
                        }
                    }
                    
                    if totalAmount.value > 0 {
                        let controller = chatMessagePaymentAlertController(
                            context: nil,
                            presentationData: strongSelf.presentationData,
                            updatedPresentationData: nil,
                            peers: chargingPeers,
                            count: count,
                            amount: totalAmount,
                            totalAmount: totalAmount,
                            hasCheck: false,
                            navigationController: strongSelf.navigationController as? NavigationController,
                            completion: { _ in
                                proceed()
                            }
                        )
                        strongSelf.present(controller, in: .window(.root))
                    } else {
                        proceed()
                    }
                })
            }
            controller.peerSelected = { [weak self, weak controller] peer, threadId in
                guard let strongSelf = self, let strongController = controller else {
                    return
                }
                let peerId = peer.id
                let accountPeerId = strongSelf.context.account.peerId
                
                if resetCurrent {
                    strongSelf.updateChatPresentationInterfaceState(animated: false, interactive: true, { $0.updatedInterfaceState({ $0.withUpdatedForwardMessageIds(nil).withUpdatedForwardOptionsState(nil) }) })
                }
                
                var isPinnedMessages = false
                if case .pinnedMessages = strongSelf.presentationInterfaceState.subject {
                    isPinnedMessages = true
                }
                
                var hasNotOwnMessages = false
                for message in messages {
                    if message.id.peerId == accountPeerId && message.forwardInfo == nil {
                    } else {
                        hasNotOwnMessages = true
                    }
                }
                
                // AYG: `!needsCopyForward` — staging into an input panel routes the send back
                // through the plain `.forward` path, which the server refuses for a protected
                // source. Falling through puts it on the copy path below instead.
                let aygNeedsCopyForward = strongSelf.aygForwardMessagesNeedCopyForward(messages) && AYGForwardingManager.shared.ignoresCopyProtection
                let needsCopyForward = aygNeedsCopyForward
                if case .peer(peerId) = strongSelf.chatLocation, strongSelf.parentController == nil, !isPinnedMessages, !needsCopyForward {
                    strongSelf.updateChatPresentationInterfaceState(animated: false, interactive: true, { $0.updatedInterfaceState({ $0.withUpdatedForwardMessageIds(messages.map { $0.id }).withUpdatedForwardOptionsState(ChatInterfaceForwardOptionsState(hideNames: !hasNotOwnMessages, hideCaptions: false, unhideNamesOnCaptionChange: false)).withoutSelectionState() }).updatedSearch(nil) })
                    strongSelf.updateItemNodesSearchTextHighlightStates()
                    strongSelf.searchResultsController = nil
                    strongController.dismiss()
                } else if peerId == strongSelf.context.account.peerId {
                    Queue.mainQueue().after(0.88) {
                        strongSelf.chatDisplayNode.hapticFeedback.success()
                    }
                    
                    let reactionItems: Signal<[ReactionItem], NoError>
                    if messages.count > 0 {
                        reactionItems = tagMessageReactions(context: strongSelf.context, subPeerId: nil)
                    } else {
                        reactionItems = .single([])
                    }
                    
                    var correlationIds: [Int64] = []
                    let builtMessages: [EnqueueMessage]
                    switch strongSelf.aygBuildForwardEnqueueMessages(from: messages, options: nil, threadId: nil) {
                    case let .messages(value):
                        builtMessages = value
                    case .unsupported:
                        strongSelf.aygPresentUnsupportedCopyForwardAlert(in: strongController)
                        return
                    }
                    let mappedMessages = builtMessages.map { message -> EnqueueMessage in
                        let correlationId = Int64.random(in: Int64.min ... Int64.max)
                        correlationIds.append(correlationId)
                        return message.withUpdatedCorrelationId(correlationId)
                    }
                    
                    let _ = (reactionItems
                    |> deliverOnMainQueue).startStandalone(next: { [weak strongSelf] reactionItems in
                        guard let strongSelf else {
                            return
                        }
                        
                        let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                        strongSelf.present(UndoOverlayController(presentationData: presentationData, content: .forward(savedMessages: true, text: messages.count == 1 ? presentationData.strings.Conversation_ForwardTooltip_SavedMessages_One : presentationData.strings.Conversation_ForwardTooltip_SavedMessages_Many), elevatedLayout: false, position: .top, animateInAsReplacement: true, action: { [weak self] value in
                            if case .info = value, let strongSelf = self {
                                let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: strongSelf.context.account.peerId))
                                |> deliverOnMainQueue).startStandalone(next: { peer in
                                    guard let strongSelf = self, let peer = peer, let navigationController = strongSelf.effectiveNavigationController else {
                                        return
                                    }
                                    
                                    strongSelf.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: strongSelf.context, chatLocation: .peer(peer), keepStack: .always, purposefulAction: {}, peekData: nil, forceOpenChat: true))
                                })
                                return true
                            }
                            return false
                        }, additionalView: messages.count > 0 ? chatShareToSavedMessagesAdditionalView(strongSelf, reactionItems: reactionItems, correlationIds: correlationIds) : nil), in: .current)
                    })
                    
                    let _ = (enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: mappedMessages)
                    |> deliverOnMainQueue).startStandalone(next: { messageIds in
                        if let strongSelf = self {
                            let signals: [Signal<Bool, NoError>] = messageIds.compactMap({ id -> Signal<Bool, NoError>? in
                                guard let id = id else {
                                    return nil
                                }
                                return strongSelf.context.account.pendingMessageManager.pendingMessageStatus(id)
                                |> mapToSignal { status, _ -> Signal<Bool, NoError> in
                                    if status != nil {
                                        return .never()
                                    } else {
                                        return .single(true)
                                    }
                                }
                                |> take(1)
                            })
                            if strongSelf.shareStatusDisposable == nil {
                                strongSelf.shareStatusDisposable = MetaDisposable()
                            }
                            strongSelf.shareStatusDisposable?.set((combineLatest(signals)
                            |> deliverOnMainQueue).startStrict())
                        }
                    })
                    strongSelf.updateChatPresentationInterfaceState(animated: false, interactive: true, { $0.updatedInterfaceState({ $0.withoutSelectionState() }) })
                    strongController.dismiss()
                } else {
                    // AYG: staging a copy-forward into the target chat's input panel would
                    // route it back through the plain `.forward` path, which is exactly what
                    // the server refuses. Send it straight away instead, and say so with the
                    // same toast a normal forward shows.
                    if aygNeedsCopyForward {
                        let forwardOptions = options ?? ChatInterfaceForwardOptionsState(hideNames: !hasNotOwnMessages, hideCaptions: false, unhideNamesOnCaptionChange: false)
                        let mappedMessages: [EnqueueMessage]
                        switch strongSelf.aygBuildForwardEnqueueMessages(from: messages, options: forwardOptions, threadId: threadId) {
                        case let .messages(value):
                            mappedMessages = value
                        case .unsupported:
                            strongSelf.aygPresentUnsupportedCopyForwardAlert(in: strongController)
                            return
                        }

                        let _ = enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: mappedMessages).startStandalone()

                        let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                        var peerName = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                        peerName = peerName.replacingOccurrences(of: "**", with: "")
                        let text = messages.count == 1 ? presentationData.strings.Conversation_ForwardTooltip_Chat_One(peerName).string : presentationData.strings.Conversation_ForwardTooltip_Chat_Many(peerName).string
                        strongSelf.present(UndoOverlayController(presentationData: presentationData, content: .forward(savedMessages: false, text: text), elevatedLayout: false, position: .bottom, animateInAsReplacement: true, action: { _ in
                            return false
                        }), in: .current)

                        strongSelf.updateChatPresentationInterfaceState(animated: false, interactive: true, { $0.updatedInterfaceState({ $0.withoutSelectionState() }) })
                        strongController.dismiss()
                        return
                    }

                    if let navigationController = strongSelf.navigationController as? NavigationController {
                        for controller in navigationController.viewControllers {
                            if let maybeChat = controller as? ChatControllerImpl {
                                if case .peer(peerId) = maybeChat.chatLocation {
                                    var isChatPinnedMessages = false
                                    if case .pinnedMessages = maybeChat.presentationInterfaceState.subject {
                                        isChatPinnedMessages = true
                                    }
                                    if !isChatPinnedMessages {
                                        maybeChat.updateChatPresentationInterfaceState(animated: false, interactive: true, { $0.updatedInterfaceState({ $0.withUpdatedForwardMessageIds(messages.map { $0.id }).withoutSelectionState() }) })
                                        strongSelf.dismiss()
                                        strongController.dismiss()
                                        return
                                    }
                                }
                            }
                        }
                    }

                    let _ = (ChatInterfaceState.update(engine: strongSelf.context.engine, peerId: peerId, threadId: threadId, { currentState in
                        return currentState.withUpdatedForwardMessageIds(messages.map { $0.id }).withUpdatedForwardOptionsState(ChatInterfaceForwardOptionsState(hideNames: !hasNotOwnMessages, hideCaptions: false, unhideNamesOnCaptionChange: false))
                    })
                    |> deliverOnMainQueue).startStandalone(completed: {
                        if let strongSelf = self {
                            let proceed: (ChatController) -> Void = { chatController in
                                strongSelf.updateChatPresentationInterfaceState(animated: false, interactive: true, { $0.updatedInterfaceState({ $0.withoutSelectionState() }) })
                                
                                let navigationController: NavigationController?
                                if let parentController = strongSelf.parentController {
                                    navigationController = (parentController.navigationController as? NavigationController)
                                } else {
                                    navigationController = strongSelf.effectiveNavigationController
                                }
                                
                                if let navigationController = navigationController {
                                    var viewControllers = navigationController.viewControllers
                                    if threadId != nil {
                                        viewControllers.insert(chatController, at: viewControllers.count - 2)
                                    } else {
                                        viewControllers.insert(chatController, at: viewControllers.count - 1)
                                    }
                                    navigationController.setViewControllers(viewControllers, animated: false)
                                    
                                    strongSelf.controllerNavigationDisposable.set((chatController.ready.get()
                                    |> SwiftSignalKit.filter { $0 }
                                    |> take(1)
                                    |> deliverOnMainQueue).startStrict(next: { [weak navigationController] _ in
                                        viewControllers.removeAll(where: { $0 is PeerSelectionController })
                                        navigationController?.setViewControllers(viewControllers, animated: true)
                                    }))
                                }
                            }
                            if let threadId = threadId {
                                let _ = (strongSelf.context.sharedContext.chatControllerForForumThread(context: strongSelf.context, peerId: peerId, threadId: threadId)
                                |> deliverOnMainQueue).startStandalone(next: { chatController in
                                    proceed(chatController)
                                })
                            } else {
                                proceed(ChatControllerImpl(context: strongSelf.context, chatLocation: .peer(id: peerId)))
                            }
                        }
                    })
                }
            }
            self.chatDisplayNode.dismissInput()
            self.effectiveNavigationController?.pushViewController(controller)
        })
    }
}
