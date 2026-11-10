import Foundation

// AYG: the value type behind the "restricted forwarding" mechanism.
//
// Split out of the manager the same way `AYGCustomizationSettings` is, so the manager
// file is only storage plus the questions the enforcement sites ask it.
//
// AyuGram for Android has **no setting for this at all**: it renames the TL field
// `noforwards` to `ayuNoforwards` on `TL_message`, `Chat` and `UserFull`, which leaves
// every stock enforcement site reading a field that is now always `false`, and consults
// the real value only from `AyuMessageUtils.isUnforwardable` / `isChatNoForwards` — the
// two predicates `AyuForward` uses to decide whether a *plain* forward is possible or
// whether the message has to be re-sent as a copy. So on Android the bypass is
// unconditional. This fork keeps the same end state but puts a switch in front of it,
// which is why the default below is `true` — flip it to `false` if the fork should ship
// opt-in instead.
public struct AYGForwardingSettings: Equatable {
    /// Ignore a peer's "Restrict Saving Content" / a message's copy-protection flag.
    ///
    /// Every place Telegram-iOS enforces content protection is a **local** UI gate
    /// except one: `messages.forwardMessages` out of a protected chat is refused by the
    /// server with `CHAT_FORWARDS_RESTRICTED`. That single case is why the mechanism is
    /// more than a boolean — see `Message.aygCopyForwardEnqueueMessage`.
    public var allowRestrictedForwarding: Bool

    public static let `default` = AYGForwardingSettings(
        allowRestrictedForwarding: true
    )
}
