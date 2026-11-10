// AYG: the message source behind Edits History and Deleted Messages.
//
// Both screens are a real `ChatController` on the chat's own peer — the chat's
// header, wallpaper, theme, bubbles, date separators and avatar button, so the
// screen is the conversation it came from, just with other messages in it — and
// this object is what the chat draws instead of the peer's history. It is the
// `ChatCustomContentsProtocol` the hashtag search feeds its result chat with, on
// the hashtag search's `kind` (the one read-only, input-less custom-contents mode
// the chat UI has), plus `AYGHistoryChatContentsMarker` so TelegramUI can tell the
// two apart where they must differ (see the marker's header in TelegramCore).
//
// Deleted Messages: the archive's rows resolve to the real postbox messages
// anti-delete kept — media, replies, reactions, the deleted mark, all as in the
// chat. A row whose message the postbox no longer has (an import, an extension's
// capture, a cleared cache) is rebuilt from the archive: text or the media
// description, the author when known, the deleted attribute so it carries the
// same mark.
//
// Edits History: `saveOriginalText` archives text only, so every revision is a
// text bubble built on the message it belongs to — its author, direction, thread
// and peers — carrying the timestamp of the edit that replaced it, oldest first.
// Revisions get ids at the top of the cloud namespace so they cannot collide with
// anything real; the marker's `aygIsRealMessage` answers false for them.

import Foundation
import UIKit
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext

public final class AYGHistoryChatContents: ChatCustomContentsProtocol, AYGHistoryChatContentsMarker {
    public enum Source {
        case edits(peerId: EnginePeer.Id, messageId: Int32, isOutgoing: Bool)
        case deleted(peerId: EnginePeer.Id)
    }

    public let source: Source
    public let aygHistoryMode: AYGHistoryChatContentsMode

    public var kind: ChatCustomContentsKind {
        return .hashTagSearch(publicPosts: false)
    }

    public var messageLimit: Int? {
        return nil
    }

    public var historyView: Signal<(EngineRawMessageHistoryView, EngineViewUpdateType), NoError> {
        return self.historyViewPromise.get()
    }

    public var hashtagSearchResultsUpdate: ((SearchMessagesResult, SearchMessagesState)) -> Void = { _ in }

    private let context: AccountContext
    private let historyViewPromise = Promise<(EngineRawMessageHistoryView, EngineViewUpdateType)>()
    private let loadDisposable = MetaDisposable()
    private let syntheticIds = Atomic<Set<MessageId>>(value: Set())
    private var observer: NSObjectProtocol?
    private var hasLoadedOnce = false

    public init(context: AccountContext, source: Source) {
        self.context = context
        self.source = source
        switch source {
        case .edits:
            self.aygHistoryMode = .edits
        case .deleted:
            self.aygHistoryMode = .deleted
        }

        self.reload()

        // The archives can change under an open screen: the Spy screen clears them,
        // the auto-clear timer runs, another edit or deletion of the same chat comes
        // in — Android re-reads too.
        let notificationName: Notification.Name
        switch source {
        case .edits:
            notificationName = EditHistoryManager.historyChangedNotification
        case .deleted:
            notificationName = AntiDeleteManager.settingsChangedNotification
        }
        self.observer = NotificationCenter.default.addObserver(forName: notificationName, object: nil, queue: .main, using: { [weak self] _ in
            self?.reload()
        })
    }

    deinit {
        self.loadDisposable.dispose()
        if let observer = self.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - AYGHistoryChatContentsMarker

    public func aygIsRealMessage(id: MessageId) -> Bool {
        return !self.syntheticIds.with { $0.contains(id) }
    }

    // MARK: - ChatCustomContentsProtocol (read-only: everything that writes is a no-op)

    public func enqueueMessages(messages: [EnqueueMessage]) {
    }

    public func deleteMessages(ids: [EngineMessage.Id]) {
    }

    public func editMessage(id: EngineMessage.Id, text: String, media: RequestEditMessageMedia, entities: TextEntitiesMessageAttribute?, webpagePreviewAttribute: WebpagePreviewMessageAttribute?, disableUrlPreview: Bool) {
    }

    public func quickReplyUpdateShortcut(value: String) {
    }

    public func businessLinkUpdate(message: String, entities: [MessageTextEntity], title: String?) {
    }

    public func loadMore() {
    }

    public func hashtagSearchUpdate(query: String) {
    }

    // MARK: - Loading

    private func reload() {
        let signal: Signal<([Message], Set<MessageId>), NoError>
        switch self.source {
        case let .edits(peerId, messageId, isOutgoing):
            signal = AYGHistoryChatContents.editRevisions(context: self.context, peerId: peerId, messageId: messageId, isOutgoing: isOutgoing)
        case let .deleted(peerId):
            signal = AYGHistoryChatContents.deletedMessages(context: self.context, peerId: peerId)
        }
        self.loadDisposable.set((signal
        |> deliverOnMainQueue).start(next: { [weak self] messages, synthetic in
            guard let self else {
                return
            }
            let _ = self.syntheticIds.swap(synthetic)
            let entries = messages.sorted(by: { $0.index < $1.index }).map { message in
                return MessageHistoryEntry(message: message, isRead: true, location: nil, monthLocation: nil, attributes: MutableMessageHistoryEntryAttributes(authorIsContact: false))
            }
            let view = MessageHistoryView(tag: nil, namespaces: .all, entries: entries, holeEarlier: false, holeLater: false, isLoading: false)
            let updateType: EngineViewUpdateType = self.hasLoadedOnce ? .Generic : .Initial
            self.hasLoadedOnce = true
            self.historyViewPromise.set(.single((view, updateType)))
        }))
    }

    /// The archive's rows as messages: the postbox's own where anti-delete kept
    /// them, rebuilt from the row otherwise.
    private static func deletedMessages(context: AccountContext, peerId: PeerId) -> Signal<([Message], Set<MessageId>), NoError> {
        let archived = AntiDeleteManager.shared.getArchivedMessages(forPeerId: peerId.toInt64())
        let accountPeerId = context.account.peerId
        return context.account.postbox.transaction { transaction -> ([Message], Set<MessageId>) in
            var result: [Message] = []
            var synthetic = Set<MessageId>()
            var seen = Set<MessageId>()
            let accountPeer = transaction.getPeer(accountPeerId)
            let chatPeer = transaction.getPeer(peerId)
            for (index, record) in archived.enumerated() {
                let id = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: record.messageId)
                if !seen.insert(id).inserted {
                    continue
                }
                if let message = transaction.getMessage(id) {
                    result.append(message)
                    continue
                }

                let isOutgoing = record.authorId == accountPeerId.toInt64()
                var author: Peer?
                if let authorId = record.authorId {
                    author = transaction.getPeer(PeerId(authorId))
                    if author == nil, let name = record.authorName, !name.isEmpty {
                        // The archive knows the name but the postbox has forgotten the
                        // peer: a throwaway user so the bubble still says who wrote it.
                        author = TelegramUser(id: PeerId(authorId), accessHash: nil, firstName: name, lastName: nil, username: record.authorUsername, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
                    }
                }
                if author == nil {
                    author = isOutgoing ? accountPeer : chatPeer
                }

                var text = record.text
                if text.isEmpty {
                    text = record.mediaDescription ?? aygString("AYGDeletedMessagesUnknownContent")
                }

                var peers = SimpleDictionary<PeerId, Peer>()
                if let chatPeer {
                    peers[chatPeer.id] = chatPeer
                }
                if let accountPeer {
                    peers[accountPeer.id] = accountPeer
                }
                if let author {
                    peers[author.id] = author
                }

                let message = Message(
                    stableId: UInt32.max - UInt32(index),
                    stableVersion: 0,
                    id: id,
                    globallyUniqueId: nil,
                    groupingKey: nil,
                    groupInfo: nil,
                    threadId: record.threadId,
                    timestamp: record.timestamp,
                    flags: isOutgoing ? [] : [.Incoming],
                    tags: [],
                    globalTags: [],
                    localTags: [],
                    customTags: [],
                    forwardInfo: nil,
                    author: author,
                    text: text,
                    // The same mark the kept bubbles carry in the chat.
                    attributes: [DeletedMessageAttribute(deletedAt: record.deletedAt)],
                    media: [],
                    peers: peers,
                    associatedMessages: SimpleDictionary(),
                    associatedMessageIds: [],
                    associatedMedia: [:],
                    associatedThreadInfo: nil,
                    associatedStories: [:]
                )
                result.append(message)
                synthetic.insert(id)
            }
            return (result, synthetic)
        }
    }

    /// The stored revisions of one message as text bubbles built on that message.
    private static func editRevisions(context: AccountContext, peerId: PeerId, messageId: Int32, isOutgoing: Bool) -> Signal<([Message], Set<MessageId>), NoError> {
        // `saveOriginalText` appends, so the records are oldest-first already.
        let records = EditHistoryManager.shared.getEditHistory(peerId: peerId.toInt64(), messageId: messageId)
        let accountPeerId = context.account.peerId
        return context.account.postbox.transaction { transaction -> ([Message], Set<MessageId>) in
            let original = transaction.getMessage(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: messageId))
            let accountPeer = transaction.getPeer(accountPeerId)
            let chatPeer = transaction.getPeer(peerId)

            let author: Peer? = original?.author ?? (isOutgoing ? accountPeer : chatPeer)
            let flags: MessageFlags = original?.flags ?? (isOutgoing ? [] : [.Incoming])
            var peers = original?.peers ?? SimpleDictionary<PeerId, Peer>()
            if let chatPeer, peers[chatPeer.id] == nil {
                peers[chatPeer.id] = chatPeer
            }
            if let accountPeer, peers[accountPeer.id] == nil {
                peers[accountPeer.id] = accountPeer
            }
            if let author, peers[author.id] == nil {
                peers[author.id] = author
            }

            var result: [Message] = []
            var synthetic = Set<MessageId>()
            // Ids climb with the records so equal edit dates still sort oldest first.
            let firstId = Int32.max - Int32(records.count)
            for (index, record) in records.enumerated() {
                let id = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: firstId + Int32(index))
                let message = Message(
                    stableId: UInt32.max - UInt32(index),
                    stableVersion: 0,
                    id: id,
                    globallyUniqueId: nil,
                    groupingKey: nil,
                    groupInfo: nil,
                    threadId: original?.threadId,
                    timestamp: record.editDate,
                    flags: flags,
                    tags: [],
                    globalTags: [],
                    localTags: [],
                    customTags: [],
                    forwardInfo: nil,
                    author: author,
                    text: record.text,
                    attributes: [],
                    media: [],
                    peers: peers,
                    associatedMessages: SimpleDictionary(),
                    associatedMessageIds: [],
                    associatedMedia: [:],
                    associatedThreadInfo: nil,
                    associatedStories: [:]
                )
                result.append(message)
                synthetic.insert(id)
            }
            return (result, synthetic)
        }
    }
}
