import Foundation

// AYG: the value types the Filters feature stores. Split out of the manager the
// same way `AYGGhostModeSettings` is, so the manager file is only storage plus
// the questions the hook sites ask it.
//
// The model is AyuGram for Android's Room schema — `RegexFilter` and
// `RegexFilterGlobalExclusion` — field for field, because the import/export
// format (`AyuFilterUtils.Backup`) is written directly out of these and a
// backup has to round-trip through Android unchanged.

// MARK: - Android dialog ids

/// Android keys filters by `long dialogId`, which is `DialogObject`'s form: a
/// user is its own id, a legacy group and a channel are both the negated id.
///
/// Every filter, exclusion and shadow-ban entry is keyed this way, so the two
/// clients' backups are interchangeable. Filters imported for a dialog this
/// client has never seen keep their raw long — Android shows
/// `Long.toString(dialogId)` for those, and so does this port.
public func aygFiltersDialogId(_ peerId: EnginePeer.Id) -> Int64 {
    let value = peerId.id._internalGetInt64Value()
    if peerId.namespace == Namespaces.Peer.CloudGroup || peerId.namespace == Namespaces.Peer.CloudChannel {
        return -value
    }
    return value
}

/// The peer ids a stored `dialogId` could name, most likely first.
///
/// The mapping above is not injective: Android negates a legacy group's id and a
/// channel's id alike, so a negative `dialogId` is one of two peers and only the
/// postbox knows which. Both are returned and the caller keeps whichever
/// resolves — which is exactly what `DialogObject.getPeerDialogId`'s inverse does
/// on Android, where the lookup goes through one shared chat cache.
public func aygFiltersCandidatePeerIds(_ dialogId: Int64) -> [EnginePeer.Id] {
    if dialogId >= 0 {
        return [EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(dialogId))]
    }
    let value = -dialogId
    return [
        EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(value)),
        EnginePeer.Id(namespace: Namespaces.Peer.CloudGroup, id: EnginePeer.Id.Id._internalFromInt64Value(value))
    ]
}

// MARK: - Filters

/// Android's `RegexFilter` row. `dialogId` is nil for a shared filter — one that
/// applies to every chat unless a `AYGFilterExclusion` switches it off for one.
public struct AYGRegexFilter: Equatable, Codable {
    public var id: UUID
    public var dialogId: Int64?
    public var text: String
    public var isEnabled: Bool
    public var caseInsensitive: Bool
    public var reversed: Bool

    public init(id: UUID, dialogId: Int64?, text: String, isEnabled: Bool, caseInsensitive: Bool, reversed: Bool) {
        self.id = id
        self.dialogId = dialogId
        self.text = text
        self.isEnabled = isEnabled
        self.caseInsensitive = caseInsensitive
        self.reversed = reversed
    }
}

/// Android's `RegexFilterGlobalExclusion`: a shared filter switched off for one
/// dialog.
public struct AYGFilterExclusion: Equatable, Codable {
    public var dialogId: Int64
    public var filterId: UUID

    public init(dialogId: Int64, filterId: UUID) {
        self.dialogId = dialogId
        self.filterId = filterId
    }
}

// MARK: - The whole configuration

/// Everything the Filters screen edits and the engine reads.
///
/// `peers` is the one field that is **not** persisted: it is a display-side
/// cache of the dialogs the screen has resolved, so a row can draw an avatar and
/// a name for a `dialogId`. Android reads the same thing out of its dialog cache
/// with `AyuMessageUtils.getDialogInAnyWay` and falls back to the raw number
/// when that misses; this port resolves peers from the postbox on demand and
/// keeps the answers here.
public struct AYGFiltersState: Equatable {
    /// `AyuConfig.filtersEnabled` — the master switch. Everything below is inert
    /// while this is off, including Shadow Ban and Hide from Blocked Users.
    public var filtersEnabled: Bool = false
    /// `AyuConfig.regexFiltersInChats`. Off, filters only run in channels and
    /// supergroups; on, they run in private chats and legacy groups too.
    public var sharedFiltersInChats: Bool = false
    /// `AyuConfig.hideFromBlocked`.
    public var hideFromBlocked: Bool = false

    public var filters: [AYGRegexFilter] = []
    public var exclusions: [AYGFilterExclusion] = []
    public var shadowBanned: [Int64] = []

    /// Display-side only; see the note on the type.
    public var peers: [Int64: EnginePeer] = [:]

    /// Android's `lastFiltersImportLink` preference, which prefills the
    /// "Import from URL" field. Written after a fetch succeeds.
    public var lastImportLink: String = ""

    public init() {
    }

    public var sharedFilters: [AYGRegexFilter] {
        return self.filters.filter { $0.dialogId == nil }
    }

    public func filters(dialogId: Int64) -> [AYGRegexFilter] {
        return self.filters.filter { $0.dialogId == dialogId }
    }

    public func exclusions(dialogId: Int64) -> [AYGRegexFilter] {
        let excluded = self.exclusions.filter { $0.dialogId == dialogId }.map { $0.filterId }
        return self.filters.filter { excluded.contains($0.id) }
    }

    /// Android walks a HashMap here, so its order is arbitrary; first appearance
    /// is the stable equivalent.
    public var dialogIds: [Int64] {
        var seen = Set<Int64>()
        var result: [Int64] = []
        for filter in self.filters {
            if let dialogId = filter.dialogId, !seen.contains(dialogId) {
                seen.insert(dialogId)
                result.append(dialogId)
            }
        }
        for exclusion in self.exclusions where !seen.contains(exclusion.dialogId) {
            seen.insert(exclusion.dialogId)
            result.append(exclusion.dialogId)
        }
        return result
    }

    public var isEmpty: Bool {
        return self.filters.isEmpty && self.exclusions.isEmpty
    }

    /// `FiltersPreferencesActivity.getUnknown`: filters pinned to a dialog this
    /// client cannot resolve. An import is what usually creates them.
    public var unknownFilterIds: [UUID] {
        var result: [UUID] = []
        for filter in self.filters {
            if let dialogId = filter.dialogId, self.peers[dialogId] == nil {
                result.append(filter.id)
            }
        }
        return result
    }

    /// `FiltersPreferencesActivity.getUnknownExclusions`: an unresolvable dialog,
    /// or an exclusion whose filter is gone.
    public var unknownExclusions: [AYGFilterExclusion] {
        return self.exclusions.filter { exclusion in
            if self.peers[exclusion.dialogId] == nil {
                return true
            }
            return !self.filters.contains(where: { $0.id == exclusion.filterId })
        }
    }
}
