import Foundation
import Postbox

// AYG: the Filters engine — a port of AyuGram for Android's
// `AyuFilterController` (the decision) and `AyuFilterCacheController` (the
// compiled-pattern cache and the per-message memo), merged into one type
// because the split there exists only to hang two `BaseController` singletons
// off the account index.
//
// # Where this runs, and what that means for cost
//
// The two call sites are `ChatHistoryListNode` (chat history) and
// `ChatListNodeEntries` (the chat list preview). Both are entry-building
// pipelines that run on a background queue once per view update — not per frame
// and not per scroll tick — over a window of roughly 50–150 messages. So the
// budget is "a few thousand regex executions per update, off the main thread",
// and two things keep it there:
//
//   * **Patterns are compiled once.** `NSRegularExpression(pattern:)` parses and
//     builds an ICU matcher; doing that inside the per-message loop would be
//     orders of magnitude more expensive than the match itself. The compiled
//     forms are rebuilt only when `AYGFiltersManager.version` moves, which
//     happens when the user edits a filter — a handful of times ever.
//   * **Match results are memoised.** The key is the message's `stableId` and
//     `stableVersion` together. `stableVersion` is bumped by Postbox whenever a
//     message's content changes, so an edited message re-matches on its own and
//     the cache needs no invalidation hook — Android needs one
//     (`AyuFilterController.invalidate`) precisely because it keys on the id
//     alone.
//
// The lock is held only around the cache dictionaries. Matching runs outside it,
// against a snapshot of the compiled patterns: `NSRegularExpression` is
// documented thread-safe for matching, and a pathological pattern must not be
// able to block the other queue.
public final class AYGFilterEngine {

    // MARK: - Singleton

    public static let shared = AYGFilterEngine()

    // MARK: - Compiled patterns

    private struct CompiledPattern {
        let regex: NSRegularExpression
        let reversed: Bool
    }

    private struct SharedPattern {
        let id: UUID
        let regex: NSRegularExpression
        let reversed: Bool
    }

    /// Everything a match needs, snapshotted so the lock can be dropped.
    private struct Snapshot {
        var isEnabled = false
        var sharedFiltersInChats = false
        var hideFromBlocked = false
        var sharedPatterns: [SharedPattern] = []
        var patternsByDialogId: [Int64: [CompiledPattern]] = [:]
        var exclusionsByDialogId: [Int64: Set<UUID>] = [:]
        var shadowBanned: Set<Int64> = []
        var blockedPeerIds: Set<Int64> = []

        /// True when nothing can possibly match, which lets the call sites skip
        /// the whole pass — including the text extraction — in the common case
        /// of a user who has never opened the Filters screen.
        var isInert: Bool {
            if !self.isEnabled {
                return true
            }
            return self.sharedPatterns.isEmpty
                && self.patternsByDialogId.isEmpty
                && self.shadowBanned.isEmpty
                && !(self.hideFromBlocked && !self.blockedPeerIds.isEmpty)
        }
    }

    private let lock = NSLock()
    private var snapshotValue = Snapshot()
    /// The `AYGFiltersManager.version` `snapshotValue` was compiled from. `-1`
    /// forces a build on first use.
    private var snapshotVersion: Int = -1

    /// dialogId → (stableId ‖ stableVersion) → matched. `AyuFilterCacheController`'s
    /// `filteredMessages`.
    private var memo: [Int64: [UInt64: Bool]] = [:]
    /// dialogId → grouping key → matched. Its `filteredGroups`: an album is one
    /// bubble, so every message in it shares the verdict of the primary one.
    private var groupMemo: [Int64: [Int64: Bool]] = [:]
    private var memoCount: Int = 0

    /// Above this the memo is dropped whole. Android never bounds its maps and
    /// relies on `rebuildCache` to clear them, which in a long session with many
    /// chats is an unbounded retain of one `Boolean` per message ever seen.
    private static let memoLimit = 8192

    private init() {
    }

    // MARK: - Pattern validation

    /// Compiles `pattern` the way the engine would, and returns the failure
    /// message if it will not compile.
    ///
    /// This is what makes a malformed expression fail at entry time rather than
    /// silently matching nothing forever: `RegexFilterEditActivity` calls
    /// `Pattern.compile` inside a `try` on Done, shows the `RegexFiltersAddError`
    /// bulletin plus the exception's message under the field, and does **not**
    /// save. The Filters editor here does the same with this.
    public static func validationError(pattern: String) -> String? {
        if pattern.isEmpty {
            return ""
        }
        do {
            _ = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            return nil
        } catch let error as NSError {
            return error.localizedDescription
        }
    }

    // MARK: - Snapshot

    /// `AyuFilterCacheController.rebuildCache`, made lazy: nothing recompiles
    /// until something asks a question after a write.
    private func currentSnapshot() -> Snapshot {
        self.lock.lock()
        defer { self.lock.unlock() }

        let version = AYGFiltersManager.shared.version
        if version == self.snapshotVersion {
            return self.snapshotValue
        }

        let state = AYGFiltersManager.shared.state
        var snapshot = Snapshot()
        snapshot.isEnabled = state.filtersEnabled
        snapshot.sharedFiltersInChats = state.sharedFiltersInChats
        snapshot.hideFromBlocked = state.hideFromBlocked
        snapshot.shadowBanned = Set(state.shadowBanned)
        snapshot.blockedPeerIds = AYGFiltersManager.shared.blockedPeerIds

        for filter in state.filters {
            guard filter.isEnabled, !filter.text.isEmpty else {
                continue
            }
            // `Pattern.compile(text, caseInsensitive ? 10 : 8)`: Java's
            // MULTILINE (8) always, plus CASE_INSENSITIVE (2). MULTILINE is
            // `.anchorsMatchLines` here — it only changes what `^` and `$` mean,
            // which matters because the haystack is many lines.
            var options: NSRegularExpression.Options = [.anchorsMatchLines]
            if filter.caseInsensitive {
                options.insert(.caseInsensitive)
            }
            // A filter that no longer compiles is skipped rather than treated as
            // matching everything. It cannot normally get here — the editor
            // refuses to save one — but an imported backup carries whatever
            // Android's regex dialect accepted, and Java and ICU do not agree on
            // every construct.
            guard let regex = try? NSRegularExpression(pattern: filter.text, options: options) else {
                continue
            }
            if let dialogId = filter.dialogId {
                snapshot.patternsByDialogId[dialogId, default: []].append(CompiledPattern(regex: regex, reversed: filter.reversed))
            } else {
                snapshot.sharedPatterns.append(SharedPattern(id: filter.id, regex: regex, reversed: filter.reversed))
            }
        }

        // `buildExclusions`: only exclusions naming a filter that actually
        // compiled are kept, so a stale exclusion cannot suppress a live filter.
        let sharedIds = Set(snapshot.sharedPatterns.map { $0.id })
        for exclusion in state.exclusions where sharedIds.contains(exclusion.filterId) {
            snapshot.exclusionsByDialogId[exclusion.dialogId, default: []].insert(exclusion.filterId)
        }

        self.snapshotValue = snapshot
        self.snapshotVersion = version
        self.memo.removeAll()
        self.groupMemo.removeAll()
        self.memoCount = 0
        return snapshot
    }

    /// `true` while no filter, shadow ban or blocked peer could hide anything.
    ///
    /// The call sites test this before they even build a message list, which is
    /// what keeps the feature free for everyone who does not use it.
    public var isInert: Bool {
        return self.currentSnapshot().isInert
    }

    // MARK: - The decision

    /// `AyuFilterController.isFiltered(chat, messageObject, groupedMessages)`.
    ///
    /// - Parameters:
    ///   - message: the message, or an album's primary message.
    ///   - groupMessages: the whole album when there is one, so its captions are
    ///     matched together and every part of it shares one verdict.
    ///   - accountPeerId: the signed-in account, so its own messages are never
    ///     filtered and its own id is never treated as shadow-banned.
    public func isFiltered(message: Message, groupMessages: [Message]?, accountPeerId: PeerId) -> Bool {
        let snapshot = self.currentSnapshot()
        if !snapshot.isEnabled {
            return false
        }
        // Android: `messageObject.isOut() || messageObject.isOutOwner()`.
        if !message.effectivelyIncoming(accountPeerId) {
            return false
        }
        if self.isSenderBlocked(message: message, snapshot: snapshot, accountPeerId: accountPeerId) {
            return true
        }

        // `isEnabled(chat)`: filters always run in a channel or supergroup;
        // everywhere else — a private chat, a legacy group — they run only with
        // "Enable Shared Filters in Chats" on.
        if !snapshot.sharedFiltersInChats {
            guard let peer = message.peers[message.id.peerId], peer is TelegramChannel else {
                return false
            }
        }

        let dialogId = aygFiltersDialogId(message.id.peerId)
        let groupingKey = groupMessages != nil ? message.groupingKey : nil
        let memoKey = (UInt64(message.stableId) << 32) | UInt64(message.stableVersion)

        if let cached = self.cachedVerdict(dialogId: dialogId, memoKey: memoKey, groupingKey: groupingKey) {
            return cached
        }

        let text = AYGFilterTextExtractor.extractAllText(message: message, groupMessages: groupMessages)
        let result = AYGFilterEngine.matches(text: text, dialogId: dialogId, snapshot: snapshot)
        self.storeVerdict(result, dialogId: dialogId, memoKey: memoKey, groupingKey: groupingKey)
        return result
    }

    /// The `EngineMessage` form, for consumers that never unwrap to Postbox.
    public func isFiltered(message: EngineMessage, groupMessages: [EngineMessage]?, accountPeerId: EnginePeer.Id) -> Bool {
        return self.isFiltered(
            message: message._asMessage(),
            groupMessages: groupMessages.map { $0.map { $0._asMessage() } },
            accountPeerId: accountPeerId
        )
    }

    // MARK: - Shadow ban and blocked users

    /// `AyuFilterController.isBlocked`. Shadow Ban wins outright; Hide from
    /// Blocked Users only applies with its own switch on. Neither ever applies
    /// to the account's own id.
    private func isBlocked(_ dialogId: Int64, snapshot: Snapshot, accountDialogId: Int64) -> Bool {
        if dialogId != accountDialogId && snapshot.shadowBanned.contains(dialogId) {
            return true
        }
        return snapshot.hideFromBlocked && snapshot.blockedPeerIds.contains(dialogId)
    }

    /// `AyuFilterController.isFilterBlocked`: the inline bot that produced the
    /// message, and — only when the sender is not the dialog itself, i.e. in a
    /// group — the sender and whoever the message was forwarded from.
    private func isSenderBlocked(message: Message, snapshot: Snapshot, accountPeerId: PeerId) -> Bool {
        if snapshot.shadowBanned.isEmpty && !(snapshot.hideFromBlocked && !snapshot.blockedPeerIds.isEmpty) {
            return false
        }
        let accountDialogId = aygFiltersDialogId(accountPeerId)

        for attribute in message.attributes {
            if let attribute = attribute as? InlineBotMessageAttribute, let peerId = attribute.peerId {
                if self.isBlocked(aygFiltersDialogId(peerId), snapshot: snapshot, accountDialogId: accountDialogId) {
                    return true
                }
            }
        }

        guard let authorId = message.author?.id, authorId != message.id.peerId else {
            return false
        }
        if self.isBlocked(aygFiltersDialogId(authorId), snapshot: snapshot, accountDialogId: accountDialogId) {
            return true
        }
        if let forwardAuthorId = message.forwardInfo?.author?.id,
           self.isBlocked(aygFiltersDialogId(forwardAuthorId), snapshot: snapshot, accountDialogId: accountDialogId) {
            return true
        }
        return false
    }

    // MARK: - Matching

    /// `AyuFilterController.isFiltered(CharSequence, long)`.
    ///
    /// The dialog's own filters run first and ignore exclusions — an exclusion is
    /// a *shared* filter switched off for one dialog, so it has nothing to say
    /// about a filter that was written for that dialog in the first place. Then
    /// the shared filters run, minus the ones this dialog excludes.
    ///
    /// `reversed` inverts one filter's verdict: a reversed filter hides
    /// everything it does **not** match.
    private static func matches(text: String, dialogId: Int64, snapshot: Snapshot) -> Bool {
        if text.isEmpty {
            return false
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)

        if let patterns = snapshot.patternsByDialogId[dialogId] {
            for pattern in patterns {
                let found = pattern.regex.firstMatch(in: text, options: [], range: range) != nil
                if found != pattern.reversed {
                    return true
                }
            }
        }

        if !snapshot.sharedPatterns.isEmpty {
            let excluded = snapshot.exclusionsByDialogId[dialogId]
            for pattern in snapshot.sharedPatterns {
                if let excluded, excluded.contains(pattern.id) {
                    continue
                }
                let found = pattern.regex.firstMatch(in: text, options: [], range: range) != nil
                if found != pattern.reversed {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Memo

    private func cachedVerdict(dialogId: Int64, memoKey: UInt64, groupingKey: Int64?) -> Bool? {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let value = self.memo[dialogId]?[memoKey] {
            return value
        }
        if let groupingKey, let value = self.groupMemo[dialogId]?[groupingKey] {
            return value
        }
        return nil
    }

    private func storeVerdict(_ value: Bool, dialogId: Int64, memoKey: UInt64, groupingKey: Int64?) {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.memoCount >= AYGFilterEngine.memoLimit {
            self.memo.removeAll(keepingCapacity: true)
            self.groupMemo.removeAll(keepingCapacity: true)
            self.memoCount = 0
        }
        self.memo[dialogId, default: [:]][memoKey] = value
        self.memoCount += 1
        if let groupingKey {
            self.groupMemo[dialogId, default: [:]][groupingKey] = value
        }
    }
}
