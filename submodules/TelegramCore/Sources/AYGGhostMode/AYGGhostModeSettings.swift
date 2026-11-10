import Foundation
import Postbox

// AYG: the value types Ghost Mode stores. Split out of the manager so the manager
// file is only storage + the questions the hook sites ask it.
//
// The model is AyuGram for Android's `GhostModeSettings`, one record per account plus
// a global one, with the five "packet" switches kept in *display* form: Android stores
// `sendReadMessagePackets` (true = normal Telegram behaviour) and inverts it for the
// checkbox, which makes every read site a double negative. Here the stored flag is the
// checkbox — `hideReadReceipts == true` means "don't send read receipts".

/// One of the five options behind the Ghost Mode master switch.
///
/// Raw values are persisted (lock flags are stored as a set of these), so they are part
/// of the on-disk format — renaming a case migrates nothing.
public enum AYGGhostModeOption: String, Codable, CaseIterable {
    case hideReadReceipts
    case hideStoryViews
    case hideOnlineStatus
    case hideTypingIndicator
    case forceOffline
}

/// "Send without Sound" — AyuGram's `sendWithoutSound` int, named.
public enum AYGSendWithoutSoundMode: Int, Codable, CaseIterable {
    case never = 0
    case inGhostMode = 1
    case always = 2
}

/// A single "what the other side sees you doing" status.
///
/// One case per `PeerInputActivity` the client can actually put on the wire through
/// `messages.setTyping`, so the suppression list and `requestActivity` cannot drift
/// apart. Ported from the source fork's `GhostModeActivityKind`.
public enum AYGGhostModeActivityKind: String, CaseIterable, Codable {
    case typingText
    case recordingVoice
    case recordingInstantVideo
    case uploadingInstantVideo
    case uploadingVideo
    case uploadingPhoto
    case uploadingFile
    case choosingSticker
    case playingGame
    case speakingInGroupCall
    case interactingWithEmoji
    case seeingEmojiInteraction

    public init(_ activity: PeerInputActivity) {
        switch activity {
        case .typingText:
            self = .typingText
        case .recordingVoice:
            self = .recordingVoice
        case .recordingInstantVideo:
            self = .recordingInstantVideo
        case .uploadingInstantVideo:
            self = .uploadingInstantVideo
        case .uploadingVideo:
            self = .uploadingVideo
        case .uploadingPhoto:
            self = .uploadingPhoto
        case .uploadingFile:
            self = .uploadingFile
        case .choosingSticker:
            self = .choosingSticker
        case .playingGame:
            self = .playingGame
        case .speakingInGroupCall:
            self = .speakingInGroupCall
        case .interactingWithEmoji:
            self = .interactingWithEmoji
        case .seeingEmojiInteraction:
            self = .seeingEmojiInteraction
        }
    }
}

/// One Ghost Mode record: either the global one or one account's.
///
/// Every field decodes with a default, so a record written by an older build — or a
/// record that predates a field — reads back without losing the fields it does have.
public struct AYGGhostModeSettings: Codable, Equatable {
    // The five options behind the master switch, in display form.
    public var hideReadReceipts: Bool
    public var hideStoryViews: Bool
    public var hideOnlineStatus: Bool
    public var hideTypingIndicator: Bool
    public var forceOffline: Bool

    /// Options pinned with a long press: the master switch leaves these alone.
    /// Android keeps a `*Locked` flag next to each option; a set is the same thing.
    public var lockedOptions: Set<AYGGhostModeOption>

    public var readOnAction: Bool
    public var useScheduledMessages: Bool
    public var sendWithoutSound: AYGSendWithoutSoundMode
    public var suggestGhostModeBeforeStory: Bool

    /// Statuses withheld while `hideTypingIndicator` is on. Unset means "all of them",
    /// which is what the single switch means on its own; an explicitly stored empty set
    /// is a different thing and withholds nothing.
    public var hiddenActivityKinds: Set<AYGGhostModeActivityKind>?

    public init(
        hideReadReceipts: Bool = false,
        hideStoryViews: Bool = false,
        hideOnlineStatus: Bool = false,
        hideTypingIndicator: Bool = false,
        forceOffline: Bool = false,
        lockedOptions: Set<AYGGhostModeOption> = [],
        readOnAction: Bool = true,
        useScheduledMessages: Bool = false,
        sendWithoutSound: AYGSendWithoutSoundMode = .never,
        suggestGhostModeBeforeStory: Bool = true,
        hiddenActivityKinds: Set<AYGGhostModeActivityKind>? = nil
    ) {
        self.hideReadReceipts = hideReadReceipts
        self.hideStoryViews = hideStoryViews
        self.hideOnlineStatus = hideOnlineStatus
        self.hideTypingIndicator = hideTypingIndicator
        self.forceOffline = forceOffline
        self.lockedOptions = lockedOptions
        self.readOnAction = readOnAction
        self.useScheduledMessages = useScheduledMessages
        self.sendWithoutSound = sendWithoutSound
        self.suggestGhostModeBeforeStory = suggestGhostModeBeforeStory
        self.hiddenActivityKinds = hiddenActivityKinds
    }

    /// AyuGram's defaults, which are all five options **off**. Ghost Mode must never be
    /// on before the user asks for it — a fresh install that silently stopped sending
    /// read receipts would be a bug, not a feature.
    public static let `default` = AYGGhostModeSettings()

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AYGGhostModeSettings.default
        self.hideReadReceipts = try container.decodeIfPresent(Bool.self, forKey: .hideReadReceipts) ?? fallback.hideReadReceipts
        self.hideStoryViews = try container.decodeIfPresent(Bool.self, forKey: .hideStoryViews) ?? fallback.hideStoryViews
        self.hideOnlineStatus = try container.decodeIfPresent(Bool.self, forKey: .hideOnlineStatus) ?? fallback.hideOnlineStatus
        self.hideTypingIndicator = try container.decodeIfPresent(Bool.self, forKey: .hideTypingIndicator) ?? fallback.hideTypingIndicator
        self.forceOffline = try container.decodeIfPresent(Bool.self, forKey: .forceOffline) ?? fallback.forceOffline
        self.lockedOptions = try container.decodeIfPresent(Set<AYGGhostModeOption>.self, forKey: .lockedOptions) ?? fallback.lockedOptions
        self.readOnAction = try container.decodeIfPresent(Bool.self, forKey: .readOnAction) ?? fallback.readOnAction
        self.useScheduledMessages = try container.decodeIfPresent(Bool.self, forKey: .useScheduledMessages) ?? fallback.useScheduledMessages
        self.sendWithoutSound = try container.decodeIfPresent(AYGSendWithoutSoundMode.self, forKey: .sendWithoutSound) ?? fallback.sendWithoutSound
        self.suggestGhostModeBeforeStory = try container.decodeIfPresent(Bool.self, forKey: .suggestGhostModeBeforeStory) ?? fallback.suggestGhostModeBeforeStory
        self.hiddenActivityKinds = try container.decodeIfPresent(Set<AYGGhostModeActivityKind>.self, forKey: .hiddenActivityKinds)
    }

    // MARK: - Option access

    public func isSelected(_ option: AYGGhostModeOption) -> Bool {
        switch option {
        case .hideReadReceipts: return self.hideReadReceipts
        case .hideStoryViews: return self.hideStoryViews
        case .hideOnlineStatus: return self.hideOnlineStatus
        case .hideTypingIndicator: return self.hideTypingIndicator
        case .forceOffline: return self.forceOffline
        }
    }

    public mutating func setSelected(_ value: Bool, for option: AYGGhostModeOption) {
        switch option {
        case .hideReadReceipts: self.hideReadReceipts = value
        case .hideStoryViews: self.hideStoryViews = value
        case .hideOnlineStatus: self.hideOnlineStatus = value
        case .hideTypingIndicator: self.hideTypingIndicator = value
        case .forceOffline: self.forceOffline = value
        }
    }

    public func isLocked(_ option: AYGGhostModeOption) -> Bool {
        return self.lockedOptions.contains(option)
    }

    /// How many of the five are in the ghost position — the `N/5` the row shows.
    /// Locked-but-off options do **not** count, which is what Android's
    /// `getGhostModeSelectedCount` does.
    public var selectedOptionCount: Int {
        return AYGGhostModeOption.allCases.reduce(into: 0) { count, option in
            if self.isSelected(option) {
                count += 1
            }
        }
    }

    /// The master switch's value.
    ///
    /// Android's `AyuGhostConfig.isGhostModeActive`: every option must be either in the
    /// ghost position **or locked**. A locked option is one the user has taken out of the
    /// master switch's hands, so it cannot be what keeps the switch off.
    public var isGhostModeActive: Bool {
        return AYGGhostModeOption.allCases.allSatisfy { self.isSelected($0) || self.isLocked($0) }
    }

    /// Drive all five from the master switch, skipping the locked ones.
    public mutating func setGhostMode(_ value: Bool) {
        for option in AYGGhostModeOption.allCases where !self.isLocked(option) {
            self.setSelected(value, for: option)
        }
    }
}

/// Per-chat exception to Ghost Mode. Each flag is "let this chat see it anyway".
///
/// Ported from the source fork's `GhostModePeerExceptionSettings`; the storage shape
/// (a JSON dictionary keyed by the stringified `PeerId.toInt64()`) is kept as-is.
public struct AYGGhostModePeerExceptionSettings: Codable, Equatable {
    public var readMessages: Bool
    public var readStories: Bool
    public var showOnlineStatus: Bool
    public var showTyping: Bool
    public var disableForceOffline: Bool
    public var readOnAction: Bool
    /// Per-chat override of the global activity list. `nil` means "inherit": the global
    /// list when Ghost Mode applies here, nothing when `showTyping` lets the chat see
    /// everything. Optional on purpose — older stored exceptions decode without the key.
    public var hiddenActivityKinds: Set<AYGGhostModeActivityKind>?
    /// AyuGram's exception is tri-state (`AyuGhostExclusions.getReadSettingsType`):
    /// Default / Never Read / Always Read. The flags above only cover the first two —
    /// they can *lift* suppression for a chat, never impose it while the account switch
    /// is off. These two are the third state: hide here regardless of the account
    /// setting. Tolerated on decode by the explicit `init(from:)` below.
    public var forceHideReadMessages: Bool
    public var forceHideTyping: Bool

    public init(
        readMessages: Bool,
        readStories: Bool,
        showOnlineStatus: Bool,
        showTyping: Bool,
        disableForceOffline: Bool,
        readOnAction: Bool,
        hiddenActivityKinds: Set<AYGGhostModeActivityKind>? = nil,
        forceHideReadMessages: Bool = false,
        forceHideTyping: Bool = false
    ) {
        self.readMessages = readMessages
        self.readStories = readStories
        self.showOnlineStatus = showOnlineStatus
        self.showTyping = showTyping
        self.disableForceOffline = disableForceOffline
        self.readOnAction = readOnAction
        self.hiddenActivityKinds = hiddenActivityKinds
        self.forceHideReadMessages = forceHideReadMessages
        self.forceHideTyping = forceHideTyping
    }

    // Synthesized `Codable` calls `decode`, not `decodeIfPresent`, for every
    // non-optional property — a default on the *init parameter* does nothing for it.
    // Without this, the first launch after the upgrade hits a missing key, and since
    // `loadExclusionSettingsLocked` decodes the whole dictionary under one `try?`, that
    // would wipe every stored per-chat exception rather than just this one field.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.readMessages = try container.decode(Bool.self, forKey: .readMessages)
        self.readStories = try container.decode(Bool.self, forKey: .readStories)
        self.showOnlineStatus = try container.decode(Bool.self, forKey: .showOnlineStatus)
        self.showTyping = try container.decode(Bool.self, forKey: .showTyping)
        self.disableForceOffline = try container.decode(Bool.self, forKey: .disableForceOffline)
        self.readOnAction = try container.decode(Bool.self, forKey: .readOnAction)
        self.hiddenActivityKinds = try container.decodeIfPresent(Set<AYGGhostModeActivityKind>.self, forKey: .hiddenActivityKinds)
        self.forceHideReadMessages = try container.decodeIfPresent(Bool.self, forKey: .forceHideReadMessages) ?? false
        self.forceHideTyping = try container.decodeIfPresent(Bool.self, forKey: .forceHideTyping) ?? false
    }

    public static let `default` = AYGGhostModePeerExceptionSettings(
        readMessages: true,
        readStories: true,
        showOnlineStatus: true,
        showTyping: true,
        disableForceOffline: true,
        readOnAction: false
    )
}
