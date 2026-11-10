import Foundation
import SwiftSignalKit

// AYG: storage for the Filters feature — the counterpart of AyuGram for
// Android's `AyuConfig` booleans plus its `RegexFilterDao` Room table.
//
// Android splits these across a SharedPreferences file (the three switches and
// `shadowBanList`) and a database (the filters and their exclusions). There are
// at most a few dozen filters, every read wants all of them at once, and the
// only writer is a settings screen — so a Room table buys nothing here. Both
// halves live in `AYGSharedDefaults.store` under the `AYG.filters.` prefix,
// which is also what makes them visible to the app extensions.
//
// `AYGSharedDefaults.store`, never `UserDefaults.standard`: the Notification
// Service and Share extensions get their own `standard` domain, so a setting
// written there is invisible to them. See `AYGSharedDefaults.swift`.
public final class AYGFiltersManager {

    // MARK: - Singleton

    public static let shared = AYGFiltersManager()

    // MARK: - UserDefaults keys

    private enum Keys {
        static let enabled = "AYG.filters.enabled"
        static let sharedInChats = "AYG.filters.sharedInChats"
        static let hideFromBlocked = "AYG.filters.hideFromBlocked"
        static let rules = "AYG.filters.rules"
        static let exclusions = "AYG.filters.exclusions"
        static let shadowBanned = "AYG.filters.shadowBanned"
        static let lastImportLink = "AYG.filters.lastImportLink"
        static let blockedPeerIds = "AYG.filters.blockedPeerIds"
    }

    // MARK: - Storage

    private let defaults = AYGSharedDefaults.store
    private let lock = NSRecursiveLock()

    private var cachedState: AYGFiltersState?
    private var cachedBlockedPeerIds: Set<Int64>?

    /// Bumped when a write changes something the engine reads — never for the
    /// display-only `peers` cache.
    ///
    /// `AYGFilterEngine` compares it against the version its compiled patterns
    /// were built from, which is what makes "recompile exactly when the filters
    /// changed" a single integer comparison on the hot path instead of a
    /// settings read; and the chat history transition takes `engineVersionSignal`
    /// as an input, so an edit re-runs the pipeline for an open chat. Both would
    /// be woken pointlessly by a peer resolving on the Filters screen.
    private var versionValue: Int = 0

    private init() {
    }

    // MARK: - Change notification

    /// Posted after any write. The Filters screen re-reads on it, and so does
    /// anything holding a `Signal` from `statePromise`.
    public static let settingsChangedNotification = Notification.Name("AYGFiltersSettingsChanged")

    private let statePipe = ValuePipe<AYGFiltersState>()
    private let versionPipe = ValuePipe<Int>()

    /// The current state, then every state after a write.
    public var stateSignal: Signal<AYGFiltersState, NoError> {
        return Signal<AYGFiltersState, NoError>.single(self.state)
        |> then(self.statePipe.signal())
    }

    /// The current `version`, then every version after a write that the engine
    /// would answer differently for. Anything that renders filtered content
    /// takes this as an input so an edit is applied immediately — the
    /// counterpart of Android's `AyuConstants.FILTERS_UPDATED` notification.
    public var engineVersionSignal: Signal<Int, NoError> {
        return Signal<Int, NoError>.single(self.version)
        |> then(self.versionPipe.signal())
    }

    // MARK: - Reading

    public var version: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.versionValue
    }

    public var state: AYGFiltersState {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.loadLocked()
    }

    private func loadLocked() -> AYGFiltersState {
        if let cached = self.cachedState {
            return cached
        }
        var state = AYGFiltersState()
        state.filtersEnabled = self.defaults.bool(forKey: Keys.enabled)
        state.sharedFiltersInChats = self.defaults.bool(forKey: Keys.sharedInChats)
        state.hideFromBlocked = self.defaults.bool(forKey: Keys.hideFromBlocked)
        state.lastImportLink = self.defaults.string(forKey: Keys.lastImportLink) ?? ""
        if let data = self.defaults.data(forKey: Keys.rules),
           let decoded = try? JSONDecoder().decode([AYGRegexFilter].self, from: data) {
            state.filters = decoded
        }
        if let data = self.defaults.data(forKey: Keys.exclusions),
           let decoded = try? JSONDecoder().decode([AYGFilterExclusion].self, from: data) {
            state.exclusions = decoded
        }
        if let data = self.defaults.data(forKey: Keys.shadowBanned),
           let decoded = try? JSONDecoder().decode([Int64].self, from: data) {
            state.shadowBanned = decoded
        }
        self.cachedState = state
        return state
    }

    // MARK: - Writing

    /// Read-modify-write under the lock, then persist and notify.
    ///
    /// `peers` is deliberately not persisted — it is the screen's display cache
    /// — but it does live in the in-memory state, so a resolve made on one
    /// screen is visible to the next one without a round trip.
    @discardableResult
    public func update(_ f: (AYGFiltersState) -> AYGFiltersState) -> AYGFiltersState {
        self.lock.lock()
        let previous = self.loadLocked()
        let updated = f(previous)
        self.cachedState = updated

        var didChangeEngineInput = false
        if updated.filtersEnabled != previous.filtersEnabled
            || updated.sharedFiltersInChats != previous.sharedFiltersInChats
            || updated.hideFromBlocked != previous.hideFromBlocked
            || updated.filters != previous.filters
            || updated.exclusions != previous.exclusions
            || updated.shadowBanned != previous.shadowBanned {
            didChangeEngineInput = true
            self.versionValue += 1
        }
        let version = self.versionValue

        if updated.filtersEnabled != previous.filtersEnabled {
            self.defaults.set(updated.filtersEnabled, forKey: Keys.enabled)
        }
        if updated.sharedFiltersInChats != previous.sharedFiltersInChats {
            self.defaults.set(updated.sharedFiltersInChats, forKey: Keys.sharedInChats)
        }
        if updated.hideFromBlocked != previous.hideFromBlocked {
            self.defaults.set(updated.hideFromBlocked, forKey: Keys.hideFromBlocked)
        }
        if updated.lastImportLink != previous.lastImportLink {
            self.defaults.set(updated.lastImportLink, forKey: Keys.lastImportLink)
        }
        if updated.filters != previous.filters, let data = try? JSONEncoder().encode(updated.filters) {
            self.defaults.set(data, forKey: Keys.rules)
        }
        if updated.exclusions != previous.exclusions, let data = try? JSONEncoder().encode(updated.exclusions) {
            self.defaults.set(data, forKey: Keys.exclusions)
        }
        if updated.shadowBanned != previous.shadowBanned, let data = try? JSONEncoder().encode(updated.shadowBanned) {
            self.defaults.set(data, forKey: Keys.shadowBanned)
        }
        self.lock.unlock()

        self.statePipe.putNext(updated)
        if didChangeEngineInput {
            self.versionPipe.putNext(version)
        }
        NotificationCenter.default.post(name: AYGFiltersManager.settingsChangedNotification, object: nil)
        return updated
    }

    // MARK: - Blocked peers

    /// The ids `hideFromBlocked` tests against, in Android's dialog-id form.
    ///
    /// Android keeps `MessagesController.blockePeers` in memory and refills it
    /// with `getBlockedPeersFull(true)` the moment the switch goes on. There is
    /// no postbox-resident blocked list on this side — `BlockedPeersContext` is
    /// a network-backed pager — so the equivalent is a persisted snapshot,
    /// refreshed from the same place Android refreshes: the Filters screen, on
    /// appearance and when the switch is turned on. That means a peer blocked
    /// elsewhere is only hidden once the screen has been opened again; the
    /// snapshot itself survives relaunches, so this is a staleness window, not a
    /// reset.
    public var blockedPeerIds: Set<Int64> {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let cached = self.cachedBlockedPeerIds {
            return cached
        }
        var result = Set<Int64>()
        if let data = self.defaults.data(forKey: Keys.blockedPeerIds),
           let decoded = try? JSONDecoder().decode([Int64].self, from: data) {
            result = Set(decoded)
        }
        self.cachedBlockedPeerIds = result
        return result
    }

    public func updateBlockedPeerIds(_ peerIds: [EnginePeer.Id]) {
        let ids = Set(peerIds.map { aygFiltersDialogId($0) })

        self.lock.lock()
        if self.cachedBlockedPeerIds == ids {
            self.lock.unlock()
            return
        }
        self.cachedBlockedPeerIds = ids
        self.versionValue += 1
        let version = self.versionValue
        if let data = try? JSONEncoder().encode(Array(ids).sorted()) {
            self.defaults.set(data, forKey: Keys.blockedPeerIds)
        }
        let state = self.loadLocked()
        self.lock.unlock()

        self.statePipe.putNext(state)
        self.versionPipe.putNext(version)
        NotificationCenter.default.post(name: AYGFiltersManager.settingsChangedNotification, object: nil)
    }
}
