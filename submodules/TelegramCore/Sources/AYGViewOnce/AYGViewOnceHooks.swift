import Foundation
import Postbox
import SwiftSignalKit

// AYG: everything the view-once burn and display paths need, so those files only ever
// gain one-line calls (CLAUDE.md: prefer adding over editing).
//
// The hook sites, in the order Telegram reaches them:
//
//   MarkMessageContentAsConsumedInteractively
//       `_internal_markMessageContentAsConsumedInteractively` — you opening the photo.
//       Upstream stamps `countdownBeginTime` onto the TTL attribute, which is what
//       registers the message with Postbox's timestamp-based attribute index; the
//       autoremove watchdog then fires and swaps the photo for `TelegramMediaExpiredContent`.
//       Not stamping it is the whole burn-stop: no timestamp, no index entry, no
//       watchdog, no swap. This is AyuGram's `createTaskForMid` skip in
//       `MessagesController.markMessageAsRead2`.
//
//       `markMessageContentAsConsumedRemotely` — the same message opened on another
//       device, arriving as `updateReadMessagesContents`. This one replaces the media
//       inline rather than going through the watchdog, so it needs its own guard.
//
//   ChatMessageInteractiveMediaNode
//       the bubble stops treating the message as secret media, so it draws the photo
//       instead of the small blurred "tap to view" placeholder. AyuGram's
//       `MessageObject.needDrawBluredPreview()` override.
//
//   GalleryData
//       tapping it opens the ordinary gallery instead of `SecretMediaPreviewController`,
//       which exists to count the view down and dismiss itself.
//
// Note what is deliberately *not* hooked: `messages.readMessageContents` still goes to
// the server. AyuGram sends it too — this feature keeps *our* copy, it does not pretend
// to the sender that the photo was never opened. Withholding read receipts is Ghost
// Mode's job, and `ManagedSynchronizeConsumeMessageContentsOperations` already exempts
// view-once from it on purpose.

/// The message is one-time media: a photo, video, voice or round video the server
/// stamped with the `0x7fffffff` sentinel timeout rather than a real countdown.
///
/// Cloud one-time media carries `AutoclearTimeoutMessageAttribute` (see
/// `StoreMessage_Telegram`); `AutoremoveTimeoutMessageAttribute` is checked too because
/// that is the shape `ApplyUpdateMessage` and the secret-chat paths produce.
public func aygIsViewOnceMessage(_ message: Message) -> Bool {
    for attribute in message.attributes {
        if let attribute = attribute as? AutoclearTimeoutMessageAttribute, attribute.timeout == viewOnceTimeout {
            return true
        }
        if let attribute = attribute as? AutoremoveTimeoutMessageAttribute, attribute.timeout == viewOnceTimeout {
            return true
        }
    }
    return false
}

/// This message's one-time media is kept instead of burned.
///
/// Called once per visible message per chat layout pass, off the main thread — the
/// setting is a cached `Bool` behind a lock, the attribute scan is over the handful of
/// attributes a message has, and the exclusion check is a lock plus a `Set` lookup.
/// The cheap half is tested first so an ordinary photo costs one `Bool` read.
public func aygKeepsViewOnceMedia(_ message: Message) -> Bool {
    guard AYGViewOnceManager.shared.keepMedia else {
        return false
    }
    guard aygIsViewOnceMessage(message) else {
        return false
    }
    // AyuGram gates the same feature on `AyuConfig.saveDeletedMessageFor(account,
    // dialogId)`, which is the anti-delete exclusion list. A chat the user excluded
    // from being saved is a chat whose one-time media we do not keep either.
    return !AntiDeleteManager.shared.isMessageExcluded(
        chatPeerId: message.id.peerId.toInt64(),
        chatPeer: message.peers[message.id.peerId],
        authorId: message.author?.id.toInt64()
    )
}

/// The one view Telegram would have charged for has already been spent.
///
/// `AyuState.isMessageBurned`. Cosmetic only: it picks the badge the bubble draws, and
/// never decides whether the media survives.
public func aygWasViewOnceMediaRevealed(_ message: Message) -> Bool {
    return AYGViewOnceManager.shared.isRevealed(peerId: message.id.peerId.toInt64(), messageId: message.id.id)
}

/// Record that the view has been spent. `AyuState.setMessageBurned`, called from the
/// same guard that declines to start the countdown.
///
/// Incoming only. `markMessageContentAsConsumedRemotely` also fires for media *we* sent
/// once the recipient opens it, and marking that "revealed" would put a badge meaning
/// "your one view is spent" on a message where no view of ours was ever involved.
func aygMarkViewOnceMediaRevealed(_ message: Message) {
    guard message.flags.contains(.Incoming) else {
        return
    }
    AYGViewOnceManager.shared.markRevealed(peerId: message.id.peerId.toInt64(), messageId: message.id.id)

    // AYG: and tell the UI to raise AyuGram's "this will not burn" notice. This is the
    // one place that catches every kind: a photo or video reveals itself by being
    // opened, a voice message or a round video by being played, and all four funnel
    // through the consume path this sits on. Posted rather than called because
    // TelegramCore cannot reach a window; the observer lives in AyuGramUI.
    guard let kind = aygViewOnceKind(of: message) else {
        return
    }
    let messageId = message.id
    Queue.mainQueue().async {
        NotificationCenter.default.post(
            name: AYGViewOnceManager.mediaRevealedNotification,
            object: nil,
            userInfo: [
                AYGViewOnceManager.mediaRevealedKindKey: kind.rawValue,
                AYGViewOnceManager.mediaRevealedMessageKey: "\(messageId.peerId.toInt64()):\(messageId.id)"
            ]
        )
    }
}

/// Which of AyuGram's four notices this message's media calls for, or `nil` when it
/// carries none of them.
func aygViewOnceKind(of message: Message) -> AYGViewOnceKind? {
    for media in message.media {
        if media is TelegramMediaImage {
            return .photo
        }
        if let file = media as? TelegramMediaFile {
            if file.isInstantVideo {
                return .roundVideo
            }
            if file.isVoice {
                return .voice
            }
            if file.isVideo {
                return .video
            }
        }
    }
    return nil
}

/// The consume path is about to stamp `countdownBeginTime` onto `attribute`. Returns
/// true when it must not — and takes the opportunity to record the spent view, because
/// this is the one moment both facts are known.
///
/// `timeout` is passed rather than read off the message because the caller has already
/// resolved which of the two attribute types it is looking at.
func aygShouldSuppressViewOnceCountdown(timeout: Int32, message: Message) -> Bool {
    guard timeout == viewOnceTimeout, aygKeepsViewOnceMedia(message) else {
        return false
    }
    aygMarkViewOnceMediaRevealed(message)
    return true
}
