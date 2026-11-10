import Foundation
import Postbox

// AYG: "Schedule Messages" — the mechanism behind AyuGram's `useScheduledMessages`.
//
// Ported from the source fork's `SendDelayManager`. Outgoing messages are turned into
// scheduled messages a few seconds out instead of being sent immediately, so the client
// never has to be online at the moment the user hits send. Media gets a longer delay
// because the upload would otherwise give the moment away anyway.
//
// One deliberate difference from the source: there is no separate `isEnabled` flag here.
// The source fork has its own Send Delay screen; this fork's only entry point is the
// "Schedule Messages" row on the Ghost Mode screen, so the switch lives in
// `AYGGhostModeSettings.useScheduledMessages` and there is exactly one source of truth.
public enum AYGSendDelayManager {

    /// Base delay for text-only messages — AyuGram's "~12 seconds".
    public static let textDelaySeconds: Double = 12.0

    /// Delay for messages carrying media — AyuGram's "longer for media".
    public static let mediaDelaySeconds: Double = 20.0

    public static func isEnabled(forAccount accountPeerId: EnginePeer.Id?) -> Bool {
        return AYGGhostModeManager.shared.shouldUseScheduledMessages(forAccount: accountPeerId)
    }

    /// The schedule time these messages should actually be sent at, or `nil` to leave
    /// them alone.
    ///
    /// Returns `explicitScheduleTime` untouched when the user has already picked one —
    /// a deliberate "send at 9am" must never be moved. Bails out for secret chats (no
    /// scheduled messages there), for the scheduled-messages screen itself, for view-once
    /// media, and for anything that already carries a schedule attribute.
    public static func effectiveScheduleTime(
        for messages: [EnqueueMessage],
        explicitScheduleTime: Int32?,
        accountPeerId: EnginePeer.Id?,
        peerId: PeerId?,
        isScheduledMessages: Bool
    ) -> Int32? {
        guard explicitScheduleTime == nil, AYGSendDelayManager.isEnabled(forAccount: accountPeerId) else {
            return explicitScheduleTime
        }
        guard !messages.isEmpty else {
            return nil
        }
        guard !isScheduledMessages else {
            return nil
        }
        if peerId?.namespace == Namespaces.Peer.SecretChat {
            return nil
        }

        var hasMedia = false
        var hasViewOnce = false
        var hasExistingSchedule = false
        // A quick reply is stored in its own message namespace and never actually sent,
        // so scheduling one would file it away where nothing ever picks it up.
        var hasQuickReply = false
        for message in messages {
            switch message {
            case let .message(_, attributes, _, mediaReference, _, _, _, _, _, _):
                if mediaReference != nil {
                    hasMedia = true
                }
                if attributes.contains(where: { $0 is AutoremoveTimeoutMessageAttribute }) {
                    hasViewOnce = true
                }
                if attributes.contains(where: { $0 is OutgoingScheduleInfoMessageAttribute }) {
                    hasExistingSchedule = true
                }
                if attributes.contains(where: { $0 is OutgoingQuickReplyMessageAttribute }) {
                    hasQuickReply = true
                }
            case let .forward(_, _, _, attributes, _):
                if attributes.contains(where: { $0 is OutgoingScheduleInfoMessageAttribute }) {
                    hasExistingSchedule = true
                }
                if attributes.contains(where: { $0 is OutgoingQuickReplyMessageAttribute }) {
                    hasQuickReply = true
                }
            }
        }

        guard !hasViewOnce, !hasExistingSchedule, !hasQuickReply else {
            return nil
        }

        let delayInterval = hasMedia ? AYGSendDelayManager.mediaDelaySeconds : AYGSendDelayManager.textDelaySeconds
        return Int32(Date().timeIntervalSince1970) + Int32(delayInterval)
    }
}
