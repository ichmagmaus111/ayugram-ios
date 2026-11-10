import Foundation
import Postbox

// AYG: everything the restricted-forwarding mechanism needs that is *not* storage.
//
// Three separate things live here, in the order the mechanism uses them:
//
// 1. `…IgnoringBypass` — the real, un-lied-to answers. Upstream's `isCopyProtected()`
//    and `Peer.isCopyProtectionEnabled` now return `false` while the setting is on, so
//    the honest values need names of their own: the forward path has to know whether a
//    *plain* forward would actually be refused, and the admin UI has to keep showing the
//    real state of the channel's own "Restrict Saving Content" switch.
//
// 2. `aygRequiresCopyForward` / `aygSupportsCopyForward` — the two halves of AyuGram for
//    Android's `AyuForward.isAyuForwardNeeded` (`AyuMessageUtils.isUnforwardable`) plus
//    the media whitelist its send path can actually reproduce.
//
// 3. `aygCopyForwardEnqueueMessage` — the send itself. This is the part that is not a
//    boolean: `messages.forwardMessages` out of a protected chat is refused **by the
//    server** (`CHAT_FORWARDS_RESTRICTED`), so unlocking the Forward button alone would
//    only produce a failed send. AyuGram's answer, and this one, is to stop forwarding
//    and start *re-sending*: build a brand-new outgoing message carrying the same text
//    and a re-uploaded copy of the media. The `AyuForwardStatusLoadingMedia` string in
//    `docs/AYGAndroidStrings.xml` ("Loading media") is that download-then-reupload step
//    surfacing in Android's UI.
public extension Message {
    /// The upstream body of `isCopyProtected()`, before the bypass was put in front of
    /// it. `.CopyProtected` is the per-message flag; the two peer branches are the
    /// channel/group `noforwards` bit.
    func aygIsCopyProtectedIgnoringBypass() -> Bool {
        if self.flags.contains(.CopyProtected) {
            return true
        } else if let group = self.peers[self.id.peerId] as? TelegramGroup, group.flags.contains(.copyProtectionEnabled) {
            return true
        } else if let channel = self.peers[self.id.peerId] as? TelegramChannel, channel.flags.contains(.copyProtectionEnabled) {
            return true
        } else {
            return false
        }
    }

    /// Whether a plain `messages.forwardMessages` of this message would be refused.
    ///
    /// Secret chats have no server-side forward at all, and a protected message is
    /// refused with `CHAT_FORWARDS_RESTRICTED`. Everything else forwards normally, and
    /// must keep doing so — a real forward preserves the "Forwarded from" header, which a
    /// copy cannot.
    ///
    /// `Message` does not carry `CachedUserData`, so a *private* chat with Restricted
    /// Saving on is invisible here; the caller has to add that from the chat state. See
    /// `ChatControllerImpl.aygMessageNeedsCopyForward`.
    var aygRequiresCopyForward: Bool {
        // AYG: kept one-time media needs the copy path for the same reason a protected
        // chat does — `messages.forwardMessages` will not carry it. The server has
        // already burned its own copy, so there is nothing left to forward *from*; what
        // we hold is a local file, and a local file can only be re-uploaded.
        if self.minAutoremoveOrClearTimeout == viewOnceTimeout, aygKeepsViewOnceMedia(self) {
            return true
        }
        // AYG: 13.0's per-message `noforwards` on bot ephemeral messages. A real forward of
        // one is refused the same way, so it takes the copy path too.
        if let ephemeralAttribute = self.attributes.first(where: { $0 is EphemeralMessageAttribute }) as? EphemeralMessageAttribute, ephemeralAttribute.isForwardingDisabled {
            return true
        }
        return self.id.peerId.namespace == Namespaces.Peer.SecretChat || self.aygIsCopyProtectedIgnoringBypass()
    }

    /// Whether a copy of this message can be reproduced faithfully enough to send.
    ///
    /// Deliberately conservative: one piece of media at most, and only kinds whose whole
    /// content is in the media object. A poll, a to-do list, a dice roll, paid content, a
    /// service action, an expired message and an embedded story are all things the client
    /// cannot recreate.
    ///
    /// One-time media used to be refused here as well, on the grounds that a client must
    /// not reproduce it. That reasoning does not survive this fork: `AYGViewOnce` already
    /// keeps such media from burning, so the bytes are on disk and the user is looking at
    /// them. Refusing the copy only stopped them sending on what they already hold. It is
    /// still refused when we are *not* keeping it — then the file really is one-shot and
    /// may already be gone — and self-destructing (timed) media stays refused outright,
    /// because its timer is the whole point and a copy would launder it.
    var aygSupportsCopyForward: Bool {
        let aygIsViewOnce = self.minAutoremoveOrClearTimeout == viewOnceTimeout
        if aygIsViewOnce {
            if !aygKeepsViewOnceMedia(self) {
                return false
            }
        } else if self.containsSecretMedia {
            return false
        }

        var supportedMedia: Media?
        for media in self.media {
            switch media {
            case is TelegramMediaAction, is TelegramMediaPoll, is TelegramMediaTodo, is TelegramMediaDice, is TelegramMediaPaidContent, is TelegramMediaExpiredContent, is TelegramMediaStory, is TelegramMediaInvoice:
                return false
            case is TelegramMediaWebpage:
                // A link preview is re-derived from the text by the receiving side.
                continue
            case is TelegramMediaImage, is TelegramMediaFile, is TelegramMediaMap, is TelegramMediaContact:
                if supportedMedia != nil {
                    return false
                }
                supportedMedia = media
            default:
                return false
            }
        }

        if supportedMedia == nil && self.text.isEmpty {
            return false
        }

        return true
    }

    /// `AyuForward.isAyuForwardNeeded`: this message needs the copy path, the bypass is
    /// on, and the copy path can actually reproduce it.
    func aygShouldUseCopyForward(withBypassEnabled bypassEnabled: Bool) -> Bool {
        guard bypassEnabled else {
            return false
        }
        return self.aygRequiresCopyForward && self.aygSupportsCopyForward
    }

    /// The single media this message's copy should carry, or `nil` for a text-only copy.
    /// Returns `nil` for anything `aygSupportsCopyForward` would have rejected too.
    var aygCopyForwardMediaReference: AnyMediaReference? {
        var supportedMedia: Media?

        for media in self.media {
            switch media {
            case is TelegramMediaAction, is TelegramMediaPoll, is TelegramMediaTodo, is TelegramMediaDice, is TelegramMediaPaidContent, is TelegramMediaExpiredContent, is TelegramMediaStory, is TelegramMediaInvoice:
                return nil
            case is TelegramMediaWebpage:
                continue
            case is TelegramMediaImage, is TelegramMediaFile, is TelegramMediaMap, is TelegramMediaContact:
                if supportedMedia != nil {
                    return nil
                }
                supportedMedia = media
            default:
                return nil
            }
        }

        guard let supportedMedia else {
            return nil
        }
        return .standalone(media: supportedMedia)
    }

    /// Build the outgoing message that stands in for a forward of `self`.
    ///
    /// `nil` means "this one cannot be copied" — the caller should say so rather than
    /// silently dropping it.
    ///
    /// The media reference is `.standalone`, and the message carries
    /// `ForceDirectMediaUploadMessageAttribute`, which is what makes this work: sending
    /// `inputMediaPhoto`/`inputMediaDocument` with a file reference that came out of a
    /// protected chat is rejected, so the upload path has to re-upload the bytes it
    /// already has on disk instead of pointing at the cloud copy.
    func aygCopyForwardEnqueueMessage(threadId: Int64?, hideCaptions: Bool, localGroupingKey: Int64?) -> EnqueueMessage? {
        if !self.aygSupportsCopyForward {
            return nil
        }

        let mediaReference = self.aygCopyForwardMediaReference
        if !self.media.isEmpty && mediaReference == nil {
            return nil
        }

        var text = self.text
        var entities = self.textEntitiesAttribute?.entities ?? []
        if hideCaptions, mediaReference != nil {
            text = ""
            entities = []
        }

        if mediaReference == nil && text.isEmpty {
            return nil
        }

        var attributes: [MessageAttribute] = []
        if !entities.isEmpty {
            attributes.append(TextEntitiesMessageAttribute(entities: entities))
        }
        for attribute in self.attributes {
            // Only the two that are purely presentational and cheap to carry across:
            // a spoilered attachment stays spoilered, and media-above-text stays above.
            if attribute is MediaSpoilerMessageAttribute || attribute is InvertMediaMessageAttribute {
                attributes.append(attribute)
            }
        }
        if mediaReference != nil {
            attributes.append(ForceDirectMediaUploadMessageAttribute())
        }

        return .message(
            text: text,
            attributes: attributes,
            inlineStickers: [:],
            mediaReference: mediaReference,
            threadId: threadId,
            replyToMessageId: nil,
            replyToStoryId: nil,
            localGroupingKey: localGroupingKey,
            correlationId: nil,
            bubbleUpEmojiOrStickersets: []
        )
    }
}

public extension Peer {
    /// The upstream body of `isCopyProtectionEnabled`, before the bypass was put in
    /// front of it. The admin-facing "Restrict Saving Content" switch must keep reading
    /// the truth — it happens to read `flags` directly, but anything that needs the real
    /// state should use this rather than re-deriving it.
    var aygIsCopyProtectionEnabledIgnoringBypass: Bool {
        switch self {
        case let group as TelegramGroup:
            return group.flags.contains(.copyProtectionEnabled)
        case let channel as TelegramChannel:
            return channel.flags.contains(.copyProtectionEnabled)
        default:
            return false
        }
    }
}

public extension CachedUserData {
    /// A one-to-one chat's content protection: `.copyProtectionEnabled` is the other
    /// side's Restricted Saving, `.myCopyProtectionEnabled` is mine. `Peer` carries
    /// neither — they live on the cached data — which is why the sites that gate on a
    /// private chat all read these two flags by hand, and why this exists to give them
    /// one bypass-aware answer instead of five copies of the same `||`.
    ///
    /// AyuGram for Android bypasses both (`userFull.ayuNoforwards_peer_enabled ||
    /// userFull.ayuNoforwards_my_enabled` in `AyuMessageUtils.isChatNoForwards` are both
    /// renamed fields), so this does too.
    var aygIsCopyProtectionEnabled: Bool {
        if AYGForwardingManager.shared.ignoresCopyProtection {
            return false
        }
        return self.aygIsCopyProtectionEnabledIgnoringBypass
    }

    var aygIsCopyProtectionEnabledIgnoringBypass: Bool {
        return self.flags.contains(.copyProtectionEnabled) || self.flags.contains(.myCopyProtectionEnabled)
    }
}

public extension EngineStoryItem {
    /// A story's own content protection: `noforwards` on `storyItem`, surfaced as
    /// `isForwardingDisabled`. Gates the share button, "Save to Gallery", the repost
    /// action and the story's `captureProtected` layers.
    ///
    /// A separate reader rather than a lie in the stored property, because
    /// `isForwardingDisabled` is also the value the client *sends* when the user posts a
    /// story with sharing off, and re-posting a story copies the flag across.
    ///
    /// Sharing a protected story is refused server-side the same way a protected message
    /// is; only the local buttons are reopened here.
    var aygIsForwardingDisabled: Bool {
        if AYGForwardingManager.shared.ignoresCopyProtection {
            return false
        }
        return self.isForwardingDisabled
    }
}

/// Forces the pending-message upload path to re-upload the media rather than re-use its
/// cloud file reference.
///
/// The whole point of the copy-forward: a photo or document that came out of a
/// `noforwards` chat cannot be re-sent by reference, so the upload has to start from the
/// bytes already in the media box. Purely local — it is filtered out before the message
/// reaches the wire, and never round-trips to the server.
public final class ForceDirectMediaUploadMessageAttribute: MessageAttribute {
    public init() {
    }

    required public init(decoder: PostboxDecoder) {
    }

    public func encode(_ encoder: PostboxEncoder) {
    }
}
