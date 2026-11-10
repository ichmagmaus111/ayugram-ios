import Foundation
import UIKit
import Display
import AccountContext
import SwiftSignalKit
import TelegramCore
import AvatarNode

public extension StoryContainerScreen {
    // AYG: Story Ghost Mode Alert. AyuGram splits `StoryViewer.open` into the gate and
    // `openInner`; this is the same split, and it has to be here rather than around the
    // `push` below because the transition hides `avatarNode` on the way — dismissing the
    // alert must leave the screen exactly as it was.
    static func openArchivedStories(context: AccountContext, parentController: ViewController, avatarNode: AvatarNode, sharedProgressDisposable: MetaDisposable?) {
        aygSuggestGhostModeBeforeStory(context: context) { [weak parentController, weak avatarNode] in
            guard let parentController, let avatarNode else {
                return
            }
            StoryContainerScreen.aygOpenArchivedStoriesInner(context: context, parentController: parentController, avatarNode: avatarNode, sharedProgressDisposable: sharedProgressDisposable)
        }
    }

    // AYG: `openArchivedStories`'s original body — AyuGram's `openInner`.
    private static func aygOpenArchivedStoriesInner(context: AccountContext, parentController: ViewController, avatarNode: AvatarNode, sharedProgressDisposable: MetaDisposable?) {
        let storyContent = StoryContentContextImpl(context: context, isHidden: true, focusedPeerId: nil, singlePeer: false)
        let signal = storyContent.state
        |> take(1)
        |> mapToSignal { state -> Signal<Void, NoError> in
            if let slice = state.slice {
                return waitUntilStoryMediaPreloaded(context: context, peerId: slice.effectivePeer.id, storyItem: slice.item.storyItem)
                |> timeout(4.0, queue: .mainQueue(), alternate: .complete())
                |> map { _ -> Void in
                }
                |> then(.single(Void()))
            } else {
                return .single(Void())
            }
        }
        |> deliverOnMainQueue
        |> map { [weak parentController, weak avatarNode] _ -> Void in
            var transitionIn: StoryContainerScreen.TransitionIn?
            if let avatarNode {
                transitionIn = StoryContainerScreen.TransitionIn(
                    sourceView: avatarNode.view,
                    sourceRect: avatarNode.view.bounds,
                    sourceCornerRadius: avatarNode.view.bounds.width * 0.5,
                    sourceIsAvatar: false
                )
                avatarNode.isHidden = true
            }
            
            let storyContainerScreen = StoryContainerScreen(
                context: context,
                content: storyContent,
                transitionIn: transitionIn,
                transitionOut: { peerId, _ in
                    if let avatarNode {
                        let destinationView = avatarNode.view
                        return StoryContainerScreen.TransitionOut(
                            destinationView: destinationView,
                            transitionView: StoryContainerScreen.TransitionView(
                                makeView: { [weak destinationView] in
                                    let parentView = UIView()
                                    if let copyView = destinationView?.snapshotContentTree(unhide: true) {
                                        parentView.addSubview(copyView)
                                    }
                                    return parentView
                                },
                                updateView: { copyView, state, transition in
                                    guard let view = copyView.subviews.first else {
                                        return
                                    }
                                    let size = state.sourceSize.interpolate(to: state.destinationSize, amount: state.progress)
                                    transition.setPosition(view: view, position: CGPoint(x: size.width * 0.5, y: size.height * 0.5))
                                    transition.setScale(view: view, scale: size.width / state.destinationSize.width)
                                },
                                insertCloneTransitionView: nil
                            ),
                            destinationRect: destinationView.bounds,
                            destinationCornerRadius: destinationView.bounds.width * 0.5,
                            destinationIsAvatar: false,
                            completed: { [weak avatarNode] in
                                guard let avatarNode else {
                                    return
                                }
                                avatarNode.isHidden = false
                            }
                        )
                    } else {
                        return nil
                    }
                }
            )
            parentController?.push(storyContainerScreen)
        }
        |> ignoreValues
        
        let disposable = avatarNode.pushLoadingStatus(signal: signal)
        if let sharedProgressDisposable {
            sharedProgressDisposable.set(disposable)
        }
    }
    
    static func openPeerStories(context: AccountContext, peerId: EnginePeer.Id, parentController: ViewController, avatarNode: AvatarNode?, sharedProgressDisposable: MetaDisposable? = nil) {
        return openPeerStoriesCustom(
            context: context,
            peerId: peerId,
            isHidden: false,
            singlePeer: true,
            parentController: parentController,
            transitionIn: { [weak avatarNode] in
                if let avatarNode {
                    let transitionIn = StoryContainerScreen.TransitionIn(
                        sourceView: avatarNode.view,
                        sourceRect: avatarNode.view.bounds,
                        sourceCornerRadius: avatarNode.view.bounds.width * 0.5,
                        sourceIsAvatar: false
                    )
                    avatarNode.isHidden = true
                    return transitionIn
                } else {
                    return nil
                }
            },
            transitionOut: { [weak avatarNode] _ in
                if let avatarNode {
                    let destinationView = avatarNode.view
                    return StoryContainerScreen.TransitionOut(
                        destinationView: destinationView,
                        transitionView: StoryContainerScreen.TransitionView(
                            makeView: { [weak destinationView] in
                                let parentView = UIView()
                                if let copyView = destinationView?.snapshotContentTree(unhide: true) {
                                    parentView.addSubview(copyView)
                                }
                                return parentView
                            },
                            updateView: { copyView, state, transition in
                                guard let view = copyView.subviews.first else {
                                    return
                                }
                                let size = state.sourceSize.interpolate(to: state.destinationSize, amount: state.progress)
                                transition.setPosition(view: view, position: CGPoint(x: size.width * 0.5, y: size.height * 0.5))
                                transition.setScale(view: view, scale: size.width / state.destinationSize.width)
                            },
                            insertCloneTransitionView: nil
                        ),
                        destinationRect: destinationView.bounds,
                        destinationCornerRadius: destinationView.bounds.width * 0.5,
                        destinationIsAvatar: false,
                        completed: { [weak avatarNode] in
                            guard let avatarNode else {
                                return
                            }
                            avatarNode.isHidden = false
                        }
                    )
                } else {
                    return nil
                }
            },
            setFocusedItem: { _ in
            },
            setProgress: { [weak avatarNode] signal in
                guard let avatarNode else {
                    return
                }
                let disposable = avatarNode.pushLoadingStatus(signal: signal)
                if let sharedProgressDisposable {
                    sharedProgressDisposable.set(disposable)
                }
            }
        )
    }
    
    // AYG: Story Ghost Mode Alert — the same `open` / `openInner` split as above. This is
    // the fork's main story-opening funnel: the chat list story tray, contacts, search,
    // peer info, a chat's avatar and the story viewer's own author header all reach the
    // viewer through here, so gating it covers all of them at once. It must run before
    // `transitionIn()`, which is where the caller hides the avatar it is animating from.
    static func openPeerStoriesCustom(
        context: AccountContext,
        peerId: EnginePeer.Id,
        focusOnId: Int32? = nil,
        isHidden: Bool,
        initialOrder: [EnginePeer.Id] = [],
        singlePeer: Bool,
        parentController: ViewController,
        transitionIn: @escaping () -> StoryContainerScreen.TransitionIn?,
        transitionOut: @escaping (EnginePeer.Id) -> StoryContainerScreen.TransitionOut?,
        setFocusedItem: @escaping (Signal<EngineStoryId?, NoError>) -> Void,
        setProgress: @escaping (Signal<Never, NoError>) -> Void,
        completion: @escaping (StoryContainerScreen) -> Void = { _ in }
    ) {
        aygSuggestGhostModeBeforeStory(context: context) { [weak parentController] in
            guard let parentController else {
                return
            }
            StoryContainerScreen.aygOpenPeerStoriesCustomInner(
                context: context,
                peerId: peerId,
                focusOnId: focusOnId,
                isHidden: isHidden,
                initialOrder: initialOrder,
                singlePeer: singlePeer,
                parentController: parentController,
                transitionIn: transitionIn,
                transitionOut: transitionOut,
                setFocusedItem: setFocusedItem,
                setProgress: setProgress,
                completion: completion
            )
        }
    }

    // AYG: `openPeerStoriesCustom`'s original body — AyuGram's `openInner`.
    private static func aygOpenPeerStoriesCustomInner(
        context: AccountContext,
        peerId: EnginePeer.Id,
        focusOnId: Int32?,
        isHidden: Bool,
        initialOrder: [EnginePeer.Id],
        singlePeer: Bool,
        parentController: ViewController,
        transitionIn: @escaping () -> StoryContainerScreen.TransitionIn?,
        transitionOut: @escaping (EnginePeer.Id) -> StoryContainerScreen.TransitionOut?,
        setFocusedItem: @escaping (Signal<EngineStoryId?, NoError>) -> Void,
        setProgress: @escaping (Signal<Never, NoError>) -> Void,
        completion: @escaping (StoryContainerScreen) -> Void
    ) {
        let storyContent = StoryContentContextImpl(context: context, isHidden: isHidden, focusedPeerId: peerId, focusedStoryId: focusOnId, singlePeer: singlePeer, fixedOrder: initialOrder)
        let signal = storyContent.state
        |> take(1)
        |> mapToSignal { state -> Signal<StoryContentContextState, NoError> in
            if let slice = state.slice {
                #if DEBUG && false
                if "".isEmpty {
                    return .single(state)
                    |> delay(4.0, queue: .mainQueue())
                }
                #endif
                
                return waitUntilStoryMediaPreloaded(context: context, peerId: slice.effectivePeer.id, storyItem: slice.item.storyItem)
                |> timeout(4.0, queue: .mainQueue(), alternate: .complete())
                |> map { _ -> StoryContentContextState in
                }
                |> then(.single(state))
            } else {
                return .single(state)
            }
        }
        |> deliverOnMainQueue
        |> map { [weak parentController] state -> Void in
            if state.slice == nil {
                return
            }
            
            let transitionIn: StoryContainerScreen.TransitionIn? = transitionIn()
            
            let storyContainerScreen = StoryContainerScreen(
                context: context,
                content: storyContent,
                transitionIn: transitionIn,
                transitionOut: { peerId, _ in
                    return transitionOut(peerId)
                }
            )
            setFocusedItem(storyContainerScreen.focusedItem)
            parentController?.push(storyContainerScreen)
            completion(storyContainerScreen)
        }
        |> ignoreValues
        
        setProgress(signal)
    }
}
