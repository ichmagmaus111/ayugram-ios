import Foundation
import TelegramApi
import Postbox
import SwiftSignalKit
import MtProtoKit

private typealias SignalKitTimer = SwiftSignalKit.Timer


private final class AccountPresenceManagerImpl {
    // AYG: Ghost Mode — "Don't Send Online" and "Go Offline Automatically".
    //
    // Stock upstream mirrors one signal onto `account.updateStatus`. Ghost Mode adds a
    // second input that can override it, so the two are resolved into an explicit target
    // state first and only then applied.
    private enum PresenceTargetState: Equatable {
        /// Follow the app: online while foregrounded, offline when not. Stock behaviour.
        case followAppForeground
        /// Never report online. `reinforce` is "Go Offline Automatically": keep re-sending
        /// the offline status, because other requests can flip the account back to online
        /// server-side and one packet at the start would not hold.
        case forceOffline(reinforce: Bool)
    }

    private let queue: Queue
    private let network: Network
    private let accountPeerId: PeerId
    let isPerformingUpdate = ValuePromise<Bool>(false, ignoreRepeated: true)
    
    private var shouldKeepOnlinePresenceDisposable: Disposable?
    private let currentRequestDisposable = MetaDisposable()
    private var onlineTimer: SignalKitTimer?
    // AYG
    private var offlineDelayedTimer: SignalKitTimer?
    private var offlineReinforcementTimer: SignalKitTimer?
    private var targetState: PresenceTargetState = .followAppForeground
    private var ghostModeObserver: NSObjectProtocol?

    private var wasOnline: Bool = false

    init(queue: Queue, shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network, accountPeerId: PeerId) {
        self.queue = queue
        self.network = network
        // AYG: Ghost Mode settings are per-account, so the manager needs to know whose
        // presence this is.
        self.accountPeerId = accountPeerId

        self.shouldKeepOnlinePresenceDisposable = (shouldKeepOnlinePresence
        |> distinctUntilChanged
        |> deliverOn(self.queue)).start(next: { [weak self] value in
            guard let `self` = self else {
                return
            }
            if self.wasOnline != value {
                self.wasOnline = value
                // AYG: route through the resolver instead of calling updatePresence
                // directly — the app going to the foreground must not undo Ghost Mode.
                self.refreshPresence(force: true)
            }
        })

        // AYG: react to the switches being flipped instead of waiting for the next app
        // focus event, which could be minutes away.
        self.ghostModeObserver = NotificationCenter.default.addObserver(
            forName: AYGGhostModeManager.settingsChangedNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async {
                self?.refreshPresence(force: true)
            }
        }
    }
    
    deinit {
        assert(self.queue.isCurrent())
        self.shouldKeepOnlinePresenceDisposable?.dispose()
        self.currentRequestDisposable.dispose()
        self.onlineTimer?.invalidate()
        // AYG
        self.offlineDelayedTimer?.invalidate()
        self.offlineReinforcementTimer?.invalidate()
        if let observer = self.ghostModeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // AYG: resolve Ghost Mode against the app's own foreground state.
    private func refreshPresence(force: Bool) {
        let hideOnlineStatus = AYGGhostModeManager.shared.shouldHideOnlineStatus(forAccount: self.accountPeerId)
        let forceOffline = AYGGhostModeManager.shared.shouldForceOffline(forAccount: self.accountPeerId)

        let nextTargetState: PresenceTargetState
        if hideOnlineStatus || forceOffline {
            // Standing in a chat that has a Ghost Mode exception means that chat is
            // allowed to see the user, and presence is global — so the only way to grant
            // it is to lift the suppression while that chat is open.
            if AYGGhostModeManager.shared.isInExcludedChat {
                nextTargetState = .followAppForeground
            } else {
                nextTargetState = .forceOffline(reinforce: forceOffline)
            }
        } else {
            nextTargetState = .followAppForeground
        }

        let didChangeTargetState = self.targetState != nextTargetState
        self.targetState = nextTargetState

        if didChangeTargetState || force {
            switch nextTargetState {
            case .followAppForeground:
                self.invalidateOfflineTimers()
                self.updatePresence(self.wasOnline)
            case let .forceOffline(reinforce):
                self.invalidateOfflineTimers()
                self.updatePresence(false)
                if reinforce {
                    self.scheduleOfflineReinforcement()
                }
            }
        }
    }

    // AYG
    private func invalidateOfflineTimers() {
        self.offlineDelayedTimer?.invalidate()
        self.offlineDelayedTimer = nil
        self.offlineReinforcementTimer?.invalidate()
        self.offlineReinforcementTimer = nil
    }

    // AYG: "Go Offline Automatically". Anything the client does — opening a chat, sending
    // a message — can put the account back online server-side, so one offline packet is
    // not enough. A short follow-up catches the flip that the user's own action causes,
    // and the repeating one holds the state for as long as the switch is on.
    private func scheduleOfflineReinforcement() {
        let delayedTimer = SignalKitTimer(timeout: 3.0, repeat: false, completion: { [weak self] in
            guard let self, case .forceOffline = self.targetState else {
                return
            }
            self.updatePresence(false)
        }, queue: self.queue)
        self.offlineDelayedTimer = delayedTimer
        delayedTimer.start()

        let repeatingTimer = SignalKitTimer(timeout: 60.0, repeat: true, completion: { [weak self] in
            guard let self, case .forceOffline = self.targetState else {
                return
            }
            self.updatePresence(false)
        }, queue: self.queue)
        self.offlineReinforcementTimer = repeatingTimer
        repeatingTimer.start()
    }

    private func updatePresence(_ isOnline: Bool) {
        let request: Signal<Api.Bool, MTRpcError>
        if isOnline {
            let timer = SignalKitTimer(timeout: 30.0, repeat: false, completion: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                // AYG: re-resolve rather than blindly re-asserting online — Ghost Mode may
                // have been switched on since the keep-alive was scheduled.
                strongSelf.refreshPresence(force: true)
            }, queue: self.queue)
            self.onlineTimer = timer
            timer.start()
            request = self.network.request(Api.functions.account.updateStatus(offline: .boolFalse))
        } else {
            self.onlineTimer?.invalidate()
            self.onlineTimer = nil
            request = self.network.request(Api.functions.account.updateStatus(offline: .boolTrue))
        }
        self.isPerformingUpdate.set(true)
        self.currentRequestDisposable.set((request
        |> `catch` { _ -> Signal<Api.Bool, NoError> in
            return .single(.boolFalse)
        }
        |> deliverOn(self.queue)).start(completed: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.isPerformingUpdate.set(false)
        }))
    }
}

final class AccountPresenceManager {
    private let queue = Queue()
    private let impl: QueueLocalObject<AccountPresenceManagerImpl>

    // AYG: `accountPeerId` is new — see AccountPresenceManagerImpl.
    init(shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network, accountPeerId: PeerId) {
        let queue = self.queue
        self.impl = QueueLocalObject(queue: self.queue, generate: {
            return AccountPresenceManagerImpl(queue: queue, shouldKeepOnlinePresence: shouldKeepOnlinePresence, network: network, accountPeerId: accountPeerId)
        })
    }
    
    func isPerformingUpdate() -> Signal<Bool, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.isPerformingUpdate.get().start(next: { value in
                    subscriber.putNext(value)
                }))
            }
            return disposable
        }
    }
}
