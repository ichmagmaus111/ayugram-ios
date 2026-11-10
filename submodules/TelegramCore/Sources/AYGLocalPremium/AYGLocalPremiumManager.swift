import Foundation
import Postbox
import SwiftSignalKit

// AYG: "Local Telegram Premium" — makes this client behave as if the account had
// Premium, without the account having Premium.
//
// Ported from the source fork's `LocalPremium/LocalPremiumManager.swift`, with its own
// infrastructure removed exactly as the Ghost Mode and anti-delete ports removed theirs:
// no `SGSimpleSettings.hasCurrentRuntimePaidAccess` DRM gate on `isEnabled`, no
// `FeatureToggleManager` tab/feature flags, no `GLEGramAccessGate`, no `GG*` anything.
// Storage is `AYGSharedDefaults.store`, not `UserDefaults.standard`.
//
// Two deliberate differences from the source fork:
//
//   * **No separate on/off flag.** The Customization screen owns the switch, so
//     `isEnabled` reads `AYGCustomizationManager.shared.localPremium` and there is only
//     one source of truth. AyuGram for Android is the same shape: `AyuConfig.localPremium`
//     is read directly by `UserConfig.isPremium`.
//
//   * **No `LocalPremiumAppearanceOverride`.** The source fork stores a local name
//     colour / profile colour / emoji status and re-applies it after every server sync.
//     Writing those locally means intercepting `_internal_updateNameColorAndEmoji` and
//     `TelegramEngine.accountData.setEmojiStatus` — files this port does not own — so
//     shipping the storage without the writers would be dead code. The flag itself is
//     what unlocks the bulk of the client-side features (premium reactions, the premium
//     emoji keyboard, story quality and stealth mode, larger folder limits in the UI);
//     the colours are the part that stays missing. See the report.
//
// How the flag survives a server sync, without a hook in `UpdatePeers.swift`:
// `updatePeers` replaces the account user with whatever the server sent, which does not
// have `.isPremium`. Rather than patch that path, the manager watches the account peer
// and re-asserts the flag whenever it disappears — `keepPremiumFlag(account:)`. The
// write cannot loop, because the re-assert is a no-op once the flag is present.
public final class AYGLocalPremiumManager {

    // MARK: - Singleton

    public static let shared = AYGLocalPremiumManager()

    private let lock = NSLock()
    /// One keeper per account, so switching accounts does not stack watchers.
    private var keepers: [PeerId: Disposable] = [:]

    private init() {}

    // MARK: - State

    /// The Customization screen's "Local Telegram Premium" switch.
    public var isEnabled: Bool {
        return AYGCustomizationManager.shared.localPremium
    }

    // MARK: - Peer rewriting

    /// The peer as this client should see it: the account user gains `.isPremium` while
    /// local premium is on.
    ///
    /// Pure and cheap — the peer is returned unchanged unless it is the account user and
    /// the flag is on. This is the function a hook in `UpdatePeers.swift` would call to
    /// rewrite peers as they come off the wire, the way the source fork does it; the
    /// keeper below achieves the same thing without that hook.
    public func applyLocalPremium(to peer: Peer, accountPeerId: PeerId) -> Peer {
        guard self.isEnabled, peer.id == accountPeerId, let user = peer as? TelegramUser else {
            return peer
        }
        guard !user.flags.contains(.isPremium) else {
            return user
        }
        var flags = user.flags
        flags.insert(.isPremium)
        return user.withUpdatedFlags(flags)
    }

    // MARK: - Applying

    /// Write the flag into the postbox for this account, or take it back out.
    ///
    /// Taking it out matters: without it, switching the row off would leave a user who is
    /// not actually Premium looking Premium until the next sync happened to overwrite the
    /// row, which could be a long time in a quiet session.
    public func updatePremiumFlag(account: Account, enabled: Bool) -> Signal<Void, NoError> {
        let accountPeerId = account.peerId
        return account.postbox.transaction { transaction -> Void in
            guard let user = transaction.getPeer(accountPeerId) as? TelegramUser else {
                return
            }
            var flags = user.flags
            if enabled {
                guard !flags.contains(.isPremium) else {
                    return
                }
                flags.insert(.isPremium)
            } else {
                guard flags.contains(.isPremium) else {
                    return
                }
                flags.remove(.isPremium)
            }
            updatePeersCustom(transaction: transaction, peers: [user.withUpdatedFlags(flags)], update: { _, updated in
                return updated
            })
        }
    }

    /// Start (or stop) keeping the flag asserted for this account.
    ///
    /// Idempotent: calling it again for an account that already has a keeper replaces it,
    /// so a second call from a second screen does not double the work.
    ///
    /// **This has to be called once per account per process for the feature to survive a
    /// server sync.** The Customization screen calls it; the natural second call site is
    /// wherever the root controllers are built, which this port does not own — see the
    /// report.
    public func keepPremiumFlag(account: Account) {
        let accountPeerId = account.peerId

        self.lock.lock()
        self.keepers[accountPeerId]?.dispose()
        self.keepers[accountPeerId] = nil
        self.lock.unlock()

        guard self.isEnabled else {
            // Switching off: put the account user back the way the server has it.
            let _ = self.updatePremiumFlag(account: account, enabled: false).start()
            return
        }

        // `peerView` fires on every write to the account user, which is exactly when the
        // flag can have been dropped — `updatePeers` replacing the row after a sync. The
        // re-assert writes only when the flag is actually missing, so this cannot spin.
        let disposable = (account.postbox.peerView(id: accountPeerId)
        |> map { view -> Bool in
            guard let user = view.peers[accountPeerId] as? TelegramUser else {
                return true
            }
            return user.flags.contains(.isPremium)
        }
        |> distinctUntilChanged
        |> filter { !$0 }
        |> mapToSignal { [weak self] _ -> Signal<Void, NoError> in
            guard let self, self.isEnabled else {
                return .complete()
            }
            return self.updatePremiumFlag(account: account, enabled: true)
        }).start()

        self.lock.lock()
        self.keepers[accountPeerId] = disposable
        self.lock.unlock()
    }

    /// Drop every keeper. Used when the switch goes off.
    public func stopKeepingPremiumFlag() {
        self.lock.lock()
        let disposables = self.keepers.values
        self.keepers.removeAll()
        self.lock.unlock()
        for disposable in disposables {
            disposable.dispose()
        }
    }
}
