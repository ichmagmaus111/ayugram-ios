import Foundation
import Postbox
import SwiftSignalKit

// AYG: Ghost Mode — the single place that answers "may this leave the device?" for
// read receipts, story views, presence and typing status.
//
// Ported from the source fork's `GhostModeManager`, with its own infrastructure removed:
// no remote feature toggles, no roles, no obfuscated endpoints, no paid-access gate. All
// state is `UserDefaults` under the `AYG.` prefix and nothing here touches the network.
//
// Two things differ from the source, both because this fork follows AyuGram's model
// rather than Ghostgram's:
//
//   * There is no separate `isEnabled` master flag. AyuGram's master switch is derived —
//     it reads "on" when all five options are in the ghost position (or locked), and
//     writing it just drives the five. So each option gates its own suppression directly.
//   * Settings are per-account with a global override, the way AyuGram's account picker
//     works. Every hook site therefore passes the account it is acting for; `nil` means
//     "no account context", which resolves to the global record.
//
// Storage layout, mirroring the source's `exclusionSettings`: each record is JSON, the
// per-account ones live in one `[String: AYGGhostModeSettings]` blob keyed by the
// stringified account user id.
public final class AYGGhostModeManager {

    // MARK: - Singleton

    public static let shared = AYGGhostModeManager()

    // MARK: - UserDefaults keys

    private enum Keys {
        static let useGlobalSettings = "AYG.GhostMode.useGlobalSettings"
        static let globalSettings = "AYG.GhostMode.globalSettings"
        static let accountSettings = "AYG.GhostMode.accountSettings"
        static let excludedPeerIds = "AYG.GhostMode.excludedPeerIds"
        static let exclusionSettings = "AYG.GhostMode.exclusionSettings"
        static let serverSyncedReadIds = "AYG.GhostMode.serverSyncedReadIds"
    }

    // MARK: - Storage

    private let defaults = AYGSharedDefaults.store
    /// `NSRecursiveLock`, not a queue: several of the accessors below re-enter through
    /// `notifySettingsChanged` observers, and a `DispatchQueue.sync` there deadlocks.
    private let lock = NSRecursiveLock()

    private var cachedGlobalSettings: AYGGhostModeSettings?
    private var cachedAccountSettings: [Int64: AYGGhostModeSettings]?
    private var cachedServerSyncedReadIds: [Int64: Int32]?

    private init() {}

    // MARK: - Notifications

    public static let settingsChangedNotification = Notification.Name("AYGGhostModeSettingsChanged")

    private func notifySettingsChanged() {
        NotificationCenter.default.post(name: AYGGhostModeManager.settingsChangedNotification, object: nil)
    }

    // MARK: - Account keying

    /// The key a record is stored under. AyuGram keys by `clientUserId`, and that is the
    /// one identifier every hook site can reach: `Account.peerId` in the engine,
    /// `AccountStateManager.accountPeerId` in the managed operations.
    private static func accountKey(_ accountPeerId: EnginePeer.Id?) -> Int64? {
        guard let accountPeerId else {
            return nil
        }
        return accountPeerId.id._internalGetInt64Value()
    }

    // MARK: - Global override

    /// `true` (the default) when every account shares the global record.
    ///
    /// AyuGram's `useGlobalConfig`. The account picker on the Ghost Mode screen is what
    /// flips it: choosing "Global Settings" sets it, choosing an account clears it.
    public var useGlobalSettings: Bool {
        get {
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.defaults.object(forKey: Keys.useGlobalSettings) == nil {
                return true
            }
            return self.defaults.bool(forKey: Keys.useGlobalSettings)
        }
        set {
            self.lock.lock()
            self.defaults.set(newValue, forKey: Keys.useGlobalSettings)
            self.lock.unlock()
            self.notifySettingsChanged()
        }
    }

    // MARK: - Records

    private func loadGlobalSettingsLocked() -> AYGGhostModeSettings {
        if let cached = self.cachedGlobalSettings {
            return cached
        }
        var result = AYGGhostModeSettings.default
        if let data = self.defaults.data(forKey: Keys.globalSettings),
           let decoded = try? JSONDecoder().decode(AYGGhostModeSettings.self, from: data) {
            result = decoded
        }
        self.cachedGlobalSettings = result
        return result
    }

    private func storeGlobalSettingsLocked(_ settings: AYGGhostModeSettings) {
        self.cachedGlobalSettings = settings
        if let data = try? JSONEncoder().encode(settings) {
            self.defaults.set(data, forKey: Keys.globalSettings)
        }
    }

    private func loadAccountSettingsLocked() -> [Int64: AYGGhostModeSettings] {
        if let cached = self.cachedAccountSettings {
            return cached
        }
        var result: [Int64: AYGGhostModeSettings] = [:]
        if let data = self.defaults.data(forKey: Keys.accountSettings),
           let stored = try? JSONDecoder().decode([String: AYGGhostModeSettings].self, from: data) {
            for (key, value) in stored {
                if let id = Int64(key) {
                    result[id] = value
                }
            }
        }
        self.cachedAccountSettings = result
        return result
    }

    private func storeAccountSettingsLocked(_ settings: [Int64: AYGGhostModeSettings]) {
        self.cachedAccountSettings = settings
        let stored = Dictionary(uniqueKeysWithValues: settings.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            self.defaults.set(data, forKey: Keys.accountSettings)
        } else {
            self.defaults.removeObject(forKey: Keys.accountSettings)
        }
    }

    /// The record actually in force for `accountPeerId`.
    ///
    /// This is what every hook site reads: with the global override on (the default) it
    /// is the global record no matter which account is asking.
    public func settings(forAccount accountPeerId: EnginePeer.Id?) -> AYGGhostModeSettings {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.useGlobalSettings {
            return self.loadGlobalSettingsLocked()
        }
        guard let key = AYGGhostModeManager.accountKey(accountPeerId) else {
            return self.loadGlobalSettingsLocked()
        }
        return self.loadAccountSettingsLocked()[key] ?? .default
    }

    /// One specific record, ignoring the global override — what the settings screen edits
    /// when its account picker has an account selected. Pass `nil` for the global record.
    public func storedSettings(forAccount accountPeerId: EnginePeer.Id?) -> AYGGhostModeSettings {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let key = AYGGhostModeManager.accountKey(accountPeerId) else {
            return self.loadGlobalSettingsLocked()
        }
        return self.loadAccountSettingsLocked()[key] ?? .default
    }

    /// Edit one specific record, ignoring the global override. Pass `nil` for the global
    /// record. Posts `settingsChangedNotification` only when something actually changed.
    public func updateStoredSettings(forAccount accountPeerId: EnginePeer.Id?, _ f: (inout AYGGhostModeSettings) -> Void) {
        self.lock.lock()
        var didChange = false
        if let key = AYGGhostModeManager.accountKey(accountPeerId) {
            var all = self.loadAccountSettingsLocked()
            var value = all[key] ?? .default
            let previous = value
            f(&value)
            if value != previous {
                all[key] = value
                self.storeAccountSettingsLocked(all)
                didChange = true
            }
        } else {
            var value = self.loadGlobalSettingsLocked()
            let previous = value
            f(&value)
            if value != previous {
                self.storeGlobalSettingsLocked(value)
                didChange = true
            }
        }
        self.lock.unlock()
        if didChange {
            self.notifySettingsChanged()
        }
    }

    /// Copy an account's record over the global one and turn the global override back on.
    ///
    /// AyuGram does exactly this when the Ghost Mode screen opens on a single-account
    /// install: with only one account there is nothing for per-account settings to mean,
    /// and leaving the override off would strand whatever that account had configured.
    public func adoptAccountSettingsAsGlobal(_ accountPeerId: EnginePeer.Id) {
        self.lock.lock()
        let key = AYGGhostModeManager.accountKey(accountPeerId)
        var all = self.loadAccountSettingsLocked()
        if let key, let value = all[key] {
            self.storeGlobalSettingsLocked(value)
            all.removeValue(forKey: key)
            self.storeAccountSettingsLocked(all)
        }
        self.defaults.set(true, forKey: Keys.useGlobalSettings)
        self.lock.unlock()
        self.notifySettingsChanged()
    }

    // MARK: - Global record, by name

    // The six switches the Ghost Mode screen drives, spelled out against the global
    // record. Per-account editing goes through `updateStoredSettings(forAccount:)`;
    // these exist so the mapping from a row to a setting is greppable by name.

    public var hideReadReceipts: Bool {
        get { self.storedSettings(forAccount: nil).hideReadReceipts }
        set { self.updateStoredSettings(forAccount: nil) { $0.hideReadReceipts = newValue } }
    }

    public var hideStoryViews: Bool {
        get { self.storedSettings(forAccount: nil).hideStoryViews }
        set { self.updateStoredSettings(forAccount: nil) { $0.hideStoryViews = newValue } }
    }

    public var hideOnlineStatus: Bool {
        get { self.storedSettings(forAccount: nil).hideOnlineStatus }
        set { self.updateStoredSettings(forAccount: nil) { $0.hideOnlineStatus = newValue } }
    }

    public var hideTypingIndicator: Bool {
        get { self.storedSettings(forAccount: nil).hideTypingIndicator }
        set { self.updateStoredSettings(forAccount: nil) { $0.hideTypingIndicator = newValue } }
    }

    public var forceOffline: Bool {
        get { self.storedSettings(forAccount: nil).forceOffline }
        set { self.updateStoredSettings(forAccount: nil) { $0.forceOffline = newValue } }
    }

    public var readOnAction: Bool {
        get { self.storedSettings(forAccount: nil).readOnAction }
        set { self.updateStoredSettings(forAccount: nil) { $0.readOnAction = newValue } }
    }

    // MARK: - Whole-account questions

    public func isGhostModeActive(forAccount accountPeerId: EnginePeer.Id?) -> Bool {
        return self.settings(forAccount: accountPeerId).isGhostModeActive
    }

    /// "Schedule Messages" — AyuGram's `isUseScheduledMessages`, which is the switch
    /// **and** Ghost Mode being active. Delaying every send is expensive enough that it
    /// should not survive turning Ghost Mode off.
    public func shouldUseScheduledMessages(forAccount accountPeerId: EnginePeer.Id?) -> Bool {
        let settings = self.settings(forAccount: accountPeerId)
        return settings.useScheduledMessages && settings.isGhostModeActive
    }

    /// "Send without Sound" — AyuGram's `isSendWithoutSound`.
    public func shouldSendWithoutSound(forAccount accountPeerId: EnginePeer.Id?) -> Bool {
        let settings = self.settings(forAccount: accountPeerId)
        switch settings.sendWithoutSound {
        case .never:
            return false
        case .inGhostMode:
            return settings.isGhostModeActive
        case .always:
            return true
        }
    }

    /// "Story Ghost Mode Alert" — AyuGram's `isSuggestGhostModeBeforeViewingStory`.
    /// Only worth asking when story views are still being sent; once they are hidden
    /// there is nothing to warn about.
    public func shouldSuggestGhostModeBeforeStory(forAccount accountPeerId: EnginePeer.Id?) -> Bool {
        let settings = self.settings(forAccount: accountPeerId)
        return settings.suggestGhostModeBeforeStory && !settings.hideStoryViews
    }

    // MARK: - Per-peer questions
    //
    // These are what the hook sites call. Each one is "the option is on for this account,
    // and this chat has no exception that lets it see the thing anyway".

    public func shouldHideReadReceipts(forAccount accountPeerId: EnginePeer.Id?, peerId: Int64) -> Bool {
        // AYG: "Never Read" — AyuGram's third exception state, which imposes suppression
        // here even with the account switch off. Checked before that switch for exactly
        // that reason.
        if let exception = self.exclusionSettings(for: peerId), exception.forceHideReadMessages {
            return true
        }
        guard self.settings(forAccount: accountPeerId).hideReadReceipts else {
            return false
        }
        guard let exception = self.exclusionSettings(for: peerId) else {
            return true
        }
        return !exception.readMessages
    }

    public func shouldHideStoryViews(forAccount accountPeerId: EnginePeer.Id?, peerId: Int64) -> Bool {
        guard self.settings(forAccount: accountPeerId).hideStoryViews else {
            return false
        }
        guard let exception = self.exclusionSettings(for: peerId) else {
            return true
        }
        return !exception.readStories
    }

    /// Presence is not per-chat — it is one global status — so this is the account-level
    /// answer. `isInExcludedChat` is the one thing that overrides it: standing in an
    /// excluded chat means that chat is allowed to see you.
    public func shouldHideOnlineStatus(forAccount accountPeerId: EnginePeer.Id?) -> Bool {
        return self.settings(forAccount: accountPeerId).hideOnlineStatus
    }

    public func shouldForceOffline(forAccount accountPeerId: EnginePeer.Id?) -> Bool {
        return self.settings(forAccount: accountPeerId).forceOffline
    }

    /// Master answer for the chat: does Ghost Mode touch activity statuses here at all.
    /// Which of them it then hides is `hiddenActivityKinds(for:)`.
    public func shouldHideTypingIndicator(forAccount accountPeerId: EnginePeer.Id?, peerId: Int64) -> Bool {
        // AYG: "Never Type", the typing half of the same tri-state.
        if let exception = self.exclusionSettings(for: peerId), exception.forceHideTyping {
            return true
        }
        guard self.settings(forAccount: accountPeerId).hideTypingIndicator else {
            return false
        }
        guard let exception = self.exclusionSettings(for: peerId) else {
            return true
        }
        return !exception.showTyping
    }

    /// The set of statuses withheld from this chat, exceptions folded in.
    ///
    /// Resolution order, most specific first:
    ///   1. the chat's own list, when the exception defines one;
    ///   2. an exception with "show typing" on → nothing is withheld;
    ///   3. the account's list.
    public func hiddenActivityKinds(forAccount accountPeerId: EnginePeer.Id?, peerId: Int64) -> Set<AYGGhostModeActivityKind> {
        let global = self.settings(forAccount: accountPeerId).hiddenActivityKinds ?? Set(AYGGhostModeActivityKind.allCases)
        guard let exception = self.exclusionSettings(for: peerId) else {
            return global
        }
        if let overrides = exception.hiddenActivityKinds {
            return overrides
        }
        return exception.showTyping ? [] : global
    }

    /// Gate for one status heading to `messages.setTyping`.
    public func shouldHideActivity(_ kind: AYGGhostModeActivityKind, forAccount accountPeerId: EnginePeer.Id?, peerId: Int64) -> Bool {
        guard self.shouldHideTypingIndicator(forAccount: accountPeerId, peerId: peerId) else {
            return false
        }
        return self.hiddenActivityKinds(forAccount: accountPeerId, peerId: peerId).contains(kind)
    }

    /// True when nothing at all may reach this chat. Lets the caller drop the trailing
    /// "stopped typing" cancel, which would otherwise be a request clearing a status the
    /// peer was never shown.
    public func shouldHideAllActivities(forAccount accountPeerId: EnginePeer.Id?, peerId: Int64) -> Bool {
        guard self.shouldHideTypingIndicator(forAccount: accountPeerId, peerId: peerId) else {
            return false
        }
        return self.hiddenActivityKinds(forAccount: accountPeerId, peerId: peerId).count == AYGGhostModeActivityKind.allCases.count
    }

    /// "Read on Interact".
    ///
    /// Gated on `hideReadReceipts` on purpose: with receipts flowing normally the chat is
    /// already marked read by the ordinary path, so all this would add is a read of chats
    /// the user never opened (sending from a share sheet, a forward picker). It only has a
    /// job to do when a receipt was being withheld.
    public func shouldReadOnAction(forAccount accountPeerId: EnginePeer.Id?, peerId: Int64) -> Bool {
        let settings = self.settings(forAccount: accountPeerId)
        guard settings.readOnAction && settings.hideReadReceipts else {
            return false
        }
        guard let exception = self.exclusionSettings(for: peerId) else {
            return true
        }
        return exception.readOnAction
    }

    // MARK: - Read-sync allowance
    //
    // "Read on Interact" has to punch a hole through the read-receipt suppression: the
    // whole point is that the receipt *does* reach the server, up to the message the user
    // acted on. The allowance is in-memory and message-id bounded — nothing newer than
    // what was read leaks out, and it does not survive a relaunch.

    /// peerId → max messageId allowed to sync. Key `0` is the un-scoped allowance.
    private let readSyncMaxId = Atomic<[Int64: Int32]>(value: [:])

    /// Allow read sync for `peerId` up to `messageId` (inclusive). Stays until cleared.
    public func allowReadSyncUpTo(peerId: Int64, messageId: Int32) {
        let _ = self.readSyncMaxId.modify { current in
            var current = current
            current[peerId] = messageId
            return current
        }
    }

    /// Is this specific message allowed through?
    public func isReadSyncAllowed(for peerId: Int64, messageId: Int32) -> Bool {
        return self.readSyncMaxId.with { current in
            guard let maxId = current[peerId] else {
                return false
            }
            return messageId <= maxId
        }
    }

    /// Does this peer have any allowance? Used where the caller pushes a whole read state
    /// rather than one message id.
    public func isReadSyncAllowed(for peerId: Int64) -> Bool {
        return self.readSyncMaxId.with { $0[peerId] != nil }
    }

    public func clearReadSyncAllowance(for peerId: Int64) {
        let _ = self.readSyncMaxId.modify { current in
            var current = current
            current.removeValue(forKey: peerId)
            return current
        }
    }

    /// Un-scoped allowance with a deadline, for the read-on-action paths: they apply the
    /// read inside a Postbox transaction and the push happens asynchronously afterwards,
    /// so there is no single call site to scope it to.
    public func allowReadSyncTemporarily(duration: Double = 3.0) {
        let _ = self.readSyncMaxId.modify { current in
            var current = current
            current[0] = Int32.max
            return current
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + duration) { [weak self] in
            let _ = self?.readSyncMaxId.modify { current in
                var current = current
                current.removeValue(forKey: 0)
                return current
            }
        }
    }

    /// The question every read-receipt hook actually asks: is this peer currently allowed
    /// to push, either scoped to it or by the un-scoped allowance.
    public func hasReadSyncAllowance(for peerId: Int64) -> Bool {
        return self.isReadSyncAllowed(for: peerId) || self.isReadSyncAllowed(for: 0)
    }

    public func hasReadSyncAllowance(for peerId: Int64, messageId: Int32) -> Bool {
        return self.isReadSyncAllowed(for: peerId, messageId: messageId) || self.isReadSyncAllowed(for: 0)
    }

    // MARK: - Server-synced read state
    //
    // While Ghost Mode is on the local read state runs ahead of the server's. This
    // records how far the server actually got, so a future "the sender has not seen this"
    // affordance has something to read; nothing is inferred from its absence.

    private func loadServerSyncedReadIdsLocked() -> [Int64: Int32] {
        if let cached = self.cachedServerSyncedReadIds {
            return cached
        }
        var result: [Int64: Int32] = [:]
        if let data = self.defaults.data(forKey: Keys.serverSyncedReadIds),
           let stored = try? JSONDecoder().decode([String: Int32].self, from: data) {
            for (key, value) in stored {
                if let id = Int64(key) {
                    result[id] = value
                }
            }
        }
        self.cachedServerSyncedReadIds = result
        return result
    }

    private func storeServerSyncedReadIdsLocked(_ ids: [Int64: Int32]) {
        self.cachedServerSyncedReadIds = ids
        let stored = Dictionary(uniqueKeysWithValues: ids.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            self.defaults.set(data, forKey: Keys.serverSyncedReadIds)
        }
    }

    /// Called when a read receipt actually reached the server.
    public func markSyncedToServer(peerId: Int64, maxMessageId: Int32) {
        self.lock.lock()
        defer { self.lock.unlock() }
        var ids = self.loadServerSyncedReadIdsLocked()
        let current = ids[peerId] ?? 0
        if maxMessageId > current {
            ids[peerId] = maxMessageId
            self.storeServerSyncedReadIdsLocked(ids)
        }
    }

    /// Ensures an entry exists, so `isMessageReadOnServer` stops falling back to `true`
    /// for a peer Ghost Mode has started withholding.
    public func ensureServerSyncTracking(peerId: Int64) {
        self.lock.lock()
        defer { self.lock.unlock() }
        var ids = self.loadServerSyncedReadIdsLocked()
        if ids[peerId] == nil {
            ids[peerId] = 0
            self.storeServerSyncedReadIdsLocked(ids)
        }
    }

    /// Does the server already know this message was read? No tracking data means Ghost
    /// Mode was never active for this peer, so the honest answer is yes.
    public func isMessageReadOnServer(peerId: Int64, messageId: Int32) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let maxSynced = self.loadServerSyncedReadIdsLocked()[peerId] else {
            return true
        }
        return messageId <= maxSynced
    }

    // MARK: - Per-chat exceptions
    //
    // Ported wholesale from the source fork, minus its folder- and class-based exclusions,
    // which needed a settings screen that keeps a peer-id snapshot up to date. What is
    // left is self-contained: an explicit set of peer ids plus one settings record each.

    public var excludedPeerIds: Set<Int64> {
        get {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let array = self.defaults.array(forKey: Keys.excludedPeerIds) as? [NSNumber] else {
                return []
            }
            return Set(array.map { $0.int64Value })
        }
        set {
            self.lock.lock()
            let ids = Set(newValue)
            self.defaults.set(ids.map { NSNumber(value: $0) }, forKey: Keys.excludedPeerIds)
            var settings = self.loadExclusionSettingsLocked()
            settings = settings.filter { ids.contains($0.key) }
            for id in ids where settings[id] == nil {
                settings[id] = .default
            }
            self.storeExclusionSettingsLocked(settings)
            self.lock.unlock()
            self.notifySettingsChanged()
        }
    }

    public var excludedPeerSettings: [Int64: AYGGhostModePeerExceptionSettings] {
        self.lock.lock()
        defer { self.lock.unlock() }
        var settings = self.loadExclusionSettingsLocked()
        for id in self.excludedPeerIdsLocked() where settings[id] == nil {
            settings[id] = .default
        }
        return settings
    }

    public func isPeerExcluded(_ peerId: Int64) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return !self.equivalentPeerIds(for: peerId).isDisjoint(with: self.excludedPeerIdsLocked())
    }

    /// The exception in force for this chat, or `nil` when there is none — which is the
    /// common case and the one every `shouldHideX(for:)` treats as "hide it".
    public func exclusionSettings(for peerId: Int64) -> AYGGhostModePeerExceptionSettings? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let storedPeerId = self.storedPeerIdLocked(for: peerId) else {
            return nil
        }
        return self.loadExclusionSettingsLocked()[storedPeerId] ?? .default
    }

    public func addExclusion(_ peerId: Int64, settings: AYGGhostModePeerExceptionSettings = .default) {
        self.lock.lock()
        var ids = self.excludedPeerIdsLocked()
        let equivalentIds = self.equivalentPeerIds(for: peerId)
        let existingId = equivalentIds.first(where: { ids.contains($0) })
        ids.insert(peerId)
        for id in equivalentIds where id != peerId {
            ids.remove(id)
        }
        self.defaults.set(ids.map { NSNumber(value: $0) }, forKey: Keys.excludedPeerIds)

        var allSettings = self.loadExclusionSettingsLocked()
        let migratedSettings = existingId.flatMap { allSettings[$0] }
        for id in equivalentIds where id != peerId {
            allSettings.removeValue(forKey: id)
        }
        allSettings[peerId] = allSettings[peerId] ?? migratedSettings ?? settings
        self.storeExclusionSettingsLocked(allSettings)
        self.lock.unlock()
        self.notifySettingsChanged()
    }

    public func removeExclusion(_ peerId: Int64) {
        self.lock.lock()
        var ids = self.excludedPeerIdsLocked()
        let equivalentIds = self.equivalentPeerIds(for: peerId)
        for id in equivalentIds {
            ids.remove(id)
        }
        self.defaults.set(ids.map { NSNumber(value: $0) }, forKey: Keys.excludedPeerIds)
        var allSettings = self.loadExclusionSettingsLocked()
        for id in equivalentIds {
            allSettings.removeValue(forKey: id)
        }
        self.storeExclusionSettingsLocked(allSettings)
        self.lock.unlock()
        if let active = self.activeExcludedPeerId, equivalentIds.contains(active) {
            let _ = self.activeExcludedPeerIdValue.swap(nil)
        }
        self.notifySettingsChanged()
    }

    public func updateExclusionSettings(for peerId: Int64, _ f: (inout AYGGhostModePeerExceptionSettings) -> Void) {
        self.lock.lock()
        guard let storedPeerId = self.storedPeerIdLocked(for: peerId) else {
            self.lock.unlock()
            return
        }
        var settings = self.loadExclusionSettingsLocked()
        var value = settings[storedPeerId] ?? .default
        f(&value)
        settings[storedPeerId] = value
        self.storeExclusionSettingsLocked(settings)
        self.lock.unlock()
        if self.activeExcludedPeerId == peerId && !self.shouldOverridePresenceInExcludedChat(peerId: peerId) {
            let _ = self.activeExcludedPeerIdValue.swap(nil)
        }
        self.notifySettingsChanged()
    }

    public func setHiddenActivityKinds(_ kinds: Set<AYGGhostModeActivityKind>?, for peerId: Int64) {
        self.updateExclusionSettings(for: peerId) {
            $0.hiddenActivityKinds = kinds
        }
    }

    // MARK: - Active excluded chat (presence override)

    /// The excluded chat the user is standing in, if any.
    ///
    /// Presence is global, so the only way an excluded chat can be allowed to see the
    /// user online is to lift the suppression entirely while that chat is open — which is
    /// what the source fork does, and why this is a single value rather than a set.
    private let activeExcludedPeerIdValue = Atomic<Int64?>(value: nil)

    public var activeExcludedPeerId: Int64? {
        return self.activeExcludedPeerIdValue.with { $0 }
    }

    public var isInExcludedChat: Bool {
        return self.activeExcludedPeerIdValue.with { $0 } != nil
    }

    public func enterChat(peerId: Int64) {
        let nextPeerId: Int64?
        if self.isPeerExcluded(peerId), self.shouldOverridePresenceInExcludedChat(peerId: peerId) {
            nextPeerId = peerId
        } else {
            nextPeerId = nil
        }
        let previousPeerId = self.activeExcludedPeerIdValue.swap(nextPeerId)
        if previousPeerId == nextPeerId {
            return
        }
        self.notifySettingsChanged()
    }

    public func exitChat(peerId: Int64) {
        guard let current = self.activeExcludedPeerIdValue.with({ $0 }) else {
            return
        }
        guard self.equivalentPeerIds(for: peerId).contains(current) else {
            return
        }
        let _ = self.activeExcludedPeerIdValue.swap(nil)
        self.notifySettingsChanged()
    }

    private func shouldOverridePresenceInExcludedChat(peerId: Int64) -> Bool {
        guard let settings = self.exclusionSettings(for: peerId) else {
            return false
        }
        return settings.showOnlineStatus || settings.disableForceOffline
    }

    // MARK: - Exception storage internals

    private func excludedPeerIdsLocked() -> Set<Int64> {
        guard let array = self.defaults.array(forKey: Keys.excludedPeerIds) as? [NSNumber] else {
            return []
        }
        return Set(array.map { $0.int64Value })
    }

    private func loadExclusionSettingsLocked() -> [Int64: AYGGhostModePeerExceptionSettings] {
        guard let data = self.defaults.data(forKey: Keys.exclusionSettings) else {
            return [:]
        }
        guard let stored = try? JSONDecoder().decode([String: AYGGhostModePeerExceptionSettings].self, from: data) else {
            return [:]
        }
        var result: [Int64: AYGGhostModePeerExceptionSettings] = [:]
        for (key, value) in stored {
            if let id = Int64(key) {
                result[id] = value
            }
        }
        return result
    }

    private func storeExclusionSettingsLocked(_ settings: [Int64: AYGGhostModePeerExceptionSettings]) {
        let stored = Dictionary(uniqueKeysWithValues: settings.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            self.defaults.set(data, forKey: Keys.exclusionSettings)
        } else {
            self.defaults.removeObject(forKey: Keys.exclusionSettings)
        }
    }

    /// Every id the same chat could have been stored under.
    ///
    /// Peer ids reach this manager two ways — `PeerId.toInt64()` (namespace packed in)
    /// and the bare `PeerId.Id`, because different upstream call sites had one or the
    /// other to hand. Matching on the whole family means an exception added from one call
    /// site is still found from the other.
    private func equivalentPeerIds(for peerId: Int64) -> Set<Int64> {
        let decodedPeerId = PeerId(peerId)
        let rawIds = Set([peerId, decodedPeerId.id._internalGetInt64Value()])
        var result: Set<Int64> = rawIds

        let namespaces: [PeerId.Namespace] = [
            Namespaces.Peer.CloudUser,
            Namespaces.Peer.CloudGroup,
            Namespaces.Peer.CloudChannel
        ]
        for rawId in rawIds {
            for namespace in namespaces {
                result.insert(PeerId(namespace: namespace, id: PeerId.Id._internalFromInt64Value(rawId)).toInt64())
            }
        }
        return result
    }

    private func storedPeerIdLocked(for peerId: Int64) -> Int64? {
        let ids = self.excludedPeerIdsLocked()
        for candidate in self.equivalentPeerIds(for: peerId) {
            if ids.contains(candidate) {
                return candidate
            }
        }
        return nil
    }
}
