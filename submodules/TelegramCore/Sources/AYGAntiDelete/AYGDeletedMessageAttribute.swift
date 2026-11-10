import Foundation
import Postbox

// AYG: Marks a message that Telegram told us to delete but that we kept.
//
// The message stays in the postbox; this attribute is what lets the chat
// history render it as "deleted" instead of dropping it. It is registered with
// Postbox in `AccountManager.swift` (`declareEncodable`) — without that call the
// attribute decodes as garbage on the next launch and the mark is lost.

public class DeletedMessageAttribute: MessageAttribute, Equatable {
    public let deletedAt: Int32
    public let deletedByPeerId: Int64?

    public var associatedMessageIds: [MessageId] { return [] }
    public var associatedPeerIds: [PeerId] { return [] }
    public var automaticTimestampBasedAttribute: (UInt16, Int32)? { return nil }

    public init(deletedAt: Int32, deletedByPeerId: Int64? = nil) {
        self.deletedAt = deletedAt
        self.deletedByPeerId = deletedByPeerId
    }

    public required init(decoder: PostboxDecoder) {
        self.deletedAt = decoder.decodeInt32ForKey("d", orElse: 0)
        self.deletedByPeerId = decoder.decodeOptionalInt64ForKey("p")
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.deletedAt, forKey: "d")
        if let peerId = self.deletedByPeerId {
            encoder.encodeInt64(peerId, forKey: "p")
        }
    }

    public static func ==(lhs: DeletedMessageAttribute, rhs: DeletedMessageAttribute) -> Bool {
        return lhs.deletedAt == rhs.deletedAt && lhs.deletedByPeerId == rhs.deletedByPeerId
    }
}

public extension Message {
    /// The message carries the attribute — i.e. it was kept by anti-delete.
    var aygIsDeletedButVisible: Bool {
        return self.attributes.contains(where: { $0 is DeletedMessageAttribute })
    }

    var aygDeletedMessageAttribute: DeletedMessageAttribute? {
        return self.attributes.first(where: { $0 is DeletedMessageAttribute }) as? DeletedMessageAttribute
    }

    /// The attribute, or the manager's own record of the deletion. The two can
    /// disagree: an extension may have journalled the capture without being able
    /// to write the attribute, and an import restores archive rows for messages
    /// the postbox never had.
    var aygIsDeleted: Bool {
        if self.aygIsDeletedButVisible {
            return true
        }
        if AntiDeleteManager.shared.isMessageDeleted(peerId: self.id.peerId.toInt64(), messageId: self.id.id) {
            return true
        }
        return AntiDeleteManager.shared.isArchivedMessage(peerId: self.id.peerId.toInt64(), messageId: self.id.id)
    }
}
