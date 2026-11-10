// AYG: a copy of SettingsUI's `ThemeSettingsChatPreviewItem` — the chat-bubble
// preview the Appearance screen puts at the top of its blocks — forked so the
// Customization screen can put AyuGram's deleted-message treatment on top of it:
//
//   * the bubble is drawn at alpha 0.7 while "Translucent Deleted Messages" is on,
//     animated over 250ms with an ease-out curve, which is exactly what
//     `ChatMessageCell.startDeletedAlphaAnimation(0.7f)` does on Android;
//   * the deleted mark is drawn immediately left of the timestamp, tinted with the
//     colour the picker under the preview selects. Android gets it there by
//     prepending `AyuMessageUtils.getDeletedIcon()` plus a space to the time string;
//     the iOS status line is built inside TelegramUI and cannot be extended from
//     here, so the glyph is positioned over the bubble instead — see `markFrame`.
//
// It is a copy, not a dependency: SettingsUI already depends on AyuGramUI, so
// AyuGramUI depending on SettingsUI would be a cycle. Same rationale as
// AYGExpandableSwitchItem.swift. If upstream ever makes the item public and moves
// it below AyuGramUI in the graph, delete this and go back to theirs.

import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext
import WallpaperBackgroundNode
import TextFormat

// AYG: `ChatPreviewMessageItem` in the original, minus the reply and the peer
// colours this screen has no use for, plus `timestamp` and `deleted` — Android's
// preview builds one `TL_message` with `date = now - 3540` and `ayuDeleted = true`.
struct AYGChatPreviewMessageItem: Equatable {
    let outgoing: Bool
    let text: String
    let timestamp: Int32
    let deleted: Bool
}

// AYG: `ChatMessageCell.startDeletedAlphaAnimation` is always called with 0.7f, and
// `setForceSemiTransparent(3)` — what the preview cell uses for its initial state —
// calls `setAlpha(0.7f)` outright.
private let aygDeletedMessageAlpha: CGFloat = 0.7
private let aygDeletedMessageAlphaDuration: Double = 0.25

// AYG: Android pads the preview cell by 11dp above and below the bubble
// (`DeletedMessagePreviewCell.setPadding(0, dp(11), 0, dp(11))`). The upstream item
// this is forked from uses 4pt.
private let aygPreviewVerticalPadding: CGFloat = 11.0

final class AYGChatPreviewItem: ListViewItem, ItemListItem {
    let context: AccountContext
    let systemStyle: ItemListSystemStyle
    let theme: PresentationTheme
    let componentTheme: PresentationTheme
    let strings: PresentationStrings
    let sectionId: ItemListSectionId
    let fontSize: PresentationFontSize
    let chatBubbleCorners: PresentationChatBubbleCorners
    let wallpaper: TelegramWallpaper
    let dateTimeFormat: PresentationDateTimeFormat
    let nameDisplayOrder: PresentationPersonNameOrder
    let messageItems: [AYGChatPreviewMessageItem]
    let translucentDeleted: Bool
    let deletedMark: UIImage?
    let deletedMarkColor: UIColor
    let deletedMarkOffsetX: CGFloat
    // AYG: Edits History draws this as a chat rather than a preview block — the
    // wallpaper fills the screen and the bubbles sit at the bottom, the way a real
    // conversation does. `nil` keeps the Customization preview's own behaviour, which
    // is to hug its content.
    let minimumContentHeight: CGFloat?

    init(context: AccountContext, systemStyle: ItemListSystemStyle = .legacy, theme: PresentationTheme, componentTheme: PresentationTheme, strings: PresentationStrings, sectionId: ItemListSectionId, fontSize: PresentationFontSize, chatBubbleCorners: PresentationChatBubbleCorners, wallpaper: TelegramWallpaper, dateTimeFormat: PresentationDateTimeFormat, nameDisplayOrder: PresentationPersonNameOrder, messageItems: [AYGChatPreviewMessageItem], translucentDeleted: Bool, deletedMark: UIImage?, deletedMarkColor: UIColor, deletedMarkOffsetX: CGFloat, minimumContentHeight: CGFloat? = nil) {
        self.context = context
        self.systemStyle = systemStyle
        self.theme = theme
        self.componentTheme = componentTheme
        self.strings = strings
        self.sectionId = sectionId
        self.fontSize = fontSize
        self.chatBubbleCorners = chatBubbleCorners
        self.wallpaper = wallpaper
        self.dateTimeFormat = dateTimeFormat
        self.nameDisplayOrder = nameDisplayOrder
        self.messageItems = messageItems
        self.translucentDeleted = translucentDeleted
        self.deletedMark = deletedMark
        self.deletedMarkColor = deletedMarkColor
        self.deletedMarkOffsetX = deletedMarkOffsetX
        self.minimumContentHeight = minimumContentHeight
    }

    // AYG: laid out on the main queue, as upstream's `ThemeSettingsChatPreviewItem` is
    // since 13.0 ("create chat preview nodes on main thread"): the layout pass creates
    // the wallpaper node and the chat message nodes, which must not happen off main.
    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        Queue.mainQueue().async {
            let node = AYGChatPreviewItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))

            node.contentSize = layout.contentSize
            node.insets = layout.insets

            completion(node, {
                return (nil, { _ in apply() })
            })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? AYGChatPreviewItemNode {
                let makeLayout = nodeValue.asyncLayout()

                let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
                completion(layout, { _ in
                    apply()
                })
            }
        }
    }
}

final class AYGChatPreviewItemNode: ListViewItemNode {
    private var backgroundNode: WallpaperBackgroundNode?
    private let topStripeNode: ASDisplayNode
    private let bottomStripeNode: ASDisplayNode
    private let maskNode: ASImageNode

    private let containerNode: ASDisplayNode
    private var messageNodes: [ListViewItemNode]?

    // AYG: lives inside the message node, not inside `containerNode`, so it shares
    // the bubble's coordinate space (`contentFrame()` is in exactly that space) and
    // is dimmed along with it when the bubble goes translucent.
    private let deletedMarkNode: ASImageNode

    private var item: AYGChatPreviewItem?

    init() {
        self.topStripeNode = ASDisplayNode()
        self.topStripeNode.isLayerBacked = true

        self.bottomStripeNode = ASDisplayNode()
        self.bottomStripeNode.isLayerBacked = true

        self.maskNode = ASImageNode()

        self.containerNode = ASDisplayNode()
        self.containerNode.subnodeTransform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)

        self.deletedMarkNode = ASImageNode()
        self.deletedMarkNode.isUserInteractionEnabled = false
        self.deletedMarkNode.displaysAsynchronously = false
        self.deletedMarkNode.displayWithoutProcessing = true

        super.init(layerBacked: false)

        self.clipsToBounds = true

        self.addSubnode(self.containerNode)
    }

    func asyncLayout() -> (_ item: AYGChatPreviewItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        let currentNodes = self.messageNodes

        var currentBackgroundNode = self.backgroundNode

        return { [weak self] item, params, neighbors in
            if currentBackgroundNode == nil {
                currentBackgroundNode = createWallpaperBackgroundNode(context: item.context, forChatDisplay: false)
            }
            currentBackgroundNode?.update(wallpaper: item.wallpaper, animated: false)
            currentBackgroundNode?.updateBubbleTheme(bubbleTheme: item.componentTheme, bubbleCorners: item.chatBubbleCorners)

            let insets: UIEdgeInsets
            let separatorHeight = UIScreenPixel

            let peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(1))
            let otherPeerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(2))

            // The list is rendered bottom-up, so the items go in reversed; keep the
            // reversed order around to match a node back to the message it renders.
            let orderedMessageItems = Array(item.messageItems.reversed())

            var items: [ListViewItem] = []
            for messageItem in orderedMessageItems {
                let peers = EngineSimpleDictionary<EnginePeer.Id, EngineRawPeer>()

                let message = EngineRawMessage(stableId: 1, stableVersion: 0, id: EngineMessage.Id(peerId: messageItem.outgoing ? otherPeerId : peerId, namespace: 0, id: 1), globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: messageItem.timestamp, flags: messageItem.outgoing ? [] : [.Incoming], tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: nil, author: messageItem.outgoing ? TelegramUser(id: otherPeerId, accessHash: nil, firstName: "", lastName: "", username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil) : nil, text: messageItem.text, attributes: [], media: [], peers: peers, associatedMessages: EngineSimpleDictionary(), associatedMessageIds: [], associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:])
                items.append(item.context.sharedContext.makeChatMessagePreviewItem(context: item.context, messages: [message], theme: item.componentTheme, strings: item.strings, wallpaper: item.wallpaper, fontSize: item.fontSize, chatBubbleCorners: item.chatBubbleCorners, dateTimeFormat: item.dateTimeFormat, nameOrder: item.nameDisplayOrder, forcedResourceStatus: nil, tapMessage: nil, clickThroughMessage: nil, backgroundNode: currentBackgroundNode, availableReactions: nil, accountPeer: nil, isCentered: false, isPreview: true, isStandalone: false, rank: nil, rankRole: nil, isGiftMessageComposerPreview: false))
            }

            var nodes: [ListViewItemNode] = []
            if let messageNodes = currentNodes {
                nodes = messageNodes
                for i in 0 ..< items.count {
                    let itemNode = messageNodes[i]
                    items[i].updateNode(async: { $0() }, node: {
                        return itemNode
                    }, params: params, neighbors: ListViewItemNeighbors(previous: i == 0 ? nil : items[i - 1].neighborDescriptor, next: i == (items.count - 1) ? nil : items[i + 1].neighborDescriptor), animation: .None, completion: { (layout, apply) in
                        let nodeFrame = CGRect(origin: itemNode.frame.origin, size: CGSize(width: layout.size.width, height: layout.size.height))

                        itemNode.contentSize = layout.contentSize
                        itemNode.insets = layout.insets
                        itemNode.frame = nodeFrame
                        itemNode.isUserInteractionEnabled = false

                        apply(ListViewItemApply())
                    })
                }
            } else {
                var messageNodes: [ListViewItemNode] = []
                for i in 0 ..< items.count {
                    var itemNode: ListViewItemNode?
                    items[i].nodeConfiguredForParams(async: { $0() }, params: params, synchronousLoads: false, neighbors: ListViewItemNeighbors(previous: i == 0 ? nil : items[i - 1].neighborDescriptor, next: i == (items.count - 1) ? nil : items[i + 1].neighborDescriptor), completion: { node, apply in
                        itemNode = node
                        apply().1(ListViewItemApply())
                    })
                    itemNode!.isUserInteractionEnabled = false
                    messageNodes.append(itemNode!)
                }
                nodes = messageNodes
            }

            // AYG: everything the deleted mark needs that only the layout pass knows.
            // The bubble's own rect only exists once the message node has been
            // applied, so the rest of the placement happens below.
            var deletedNodeIndex: Int?
            for (index, messageItem) in orderedMessageItems.enumerated() where messageItem.deleted {
                deletedNodeIndex = index
            }

            var markImage: UIImage?
            if let image = item.deletedMark {
                markImage = generateTintedImage(image: image, color: item.deletedMarkColor)
            }

            // Mirrors `chatMessageItemLayoutConstants`: the text bubble's side inset
            // is interpolated between the compact/regular base and 11pt by the
            // bubble corner radius, and the bottom inset is a plain constant.
            let baseTextInset: CGFloat = params.width > 680.0 ? 10.0 : 11.0
            let radiusTransition = (item.chatBubbleCorners.mainRadius - 4.0) / (16.0 - 4.0)
            let bubbleTextInsetRight = min(11.0, ceil(11.0 * radiusTransition + baseTextInset * (1.0 - radiusTransition)))
            let bubbleTextInsetBottom: CGFloat = 6.0 - UIScreenPixel

            // The timestamp is right-aligned inside the bubble, so the mark goes one
            // space to its left — Android composes exactly `icon + " " + time`.
            var markTrailingWidth: CGFloat = 0.0
            var dateHeight: CGFloat = 0.0
            if let deletedNodeIndex = deletedNodeIndex {
                let dateFont = Font.regular(floor(item.fontSize.baseDisplaySize * 11.0 / 17.0))
                let attributes: [NSAttributedString.Key: Any] = [.font: dateFont]
                let dateText = stringForMessageTimestamp(timestamp: orderedMessageItems[deletedNodeIndex].timestamp, dateTimeFormat: item.dateTimeFormat)
                let dateSize = (dateText as NSString).size(withAttributes: attributes)
                markTrailingWidth = dateSize.width + (" " as NSString).size(withAttributes: attributes).width
                dateHeight = dateSize.height
            }

            var contentSize = CGSize(width: params.width, height: aygPreviewVerticalPadding * 2.0)
            for node in nodes {
                contentSize.height += node.frame.size.height
            }
            insets = itemListNeighborsGroupedInsets(neighbors, params)

            if let minimumContentHeight = item.minimumContentHeight {
                contentSize.height = max(contentSize.height, minimumContentHeight)
            }
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)
            let layoutSize = layout.size

            return (layout, { [weak self] in
                if let strongSelf = self {
                    let previousItem = strongSelf.item
                    strongSelf.item = item

                    strongSelf.containerNode.frame = CGRect(origin: CGPoint(), size: contentSize)

                    strongSelf.messageNodes = nodes
                    // `containerNode` is rotated by π, so a child laid out near the top
                    // of the container appears near the *bottom* of it. Keeping the
                    // offset at the padding is therefore what rests the bubbles on the
                    // bottom edge once the block has been stretched; adding the slack
                    // here would push them to the top instead.
                    var topOffset: CGFloat = aygPreviewVerticalPadding
                    for node in nodes {
                        if node.supernode == nil {
                            strongSelf.containerNode.addSubnode(node)
                        }
                        node.updateFrame(CGRect(origin: CGPoint(x: 0.0, y: topOffset), size: node.frame.size), within: layoutSize)
                        topOffset += node.frame.size.height
                    }

                    // AYG: the deleted-message treatment.
                    if let deletedNodeIndex = deletedNodeIndex, deletedNodeIndex < nodes.count {
                        let deletedNode = nodes[deletedNodeIndex]

                        let alpha: CGFloat = item.translucentDeleted ? aygDeletedMessageAlpha : 1.0
                        let previousAlpha: CGFloat = (previousItem?.translucentDeleted ?? item.translucentDeleted) ? aygDeletedMessageAlpha : 1.0
                        deletedNode.alpha = alpha
                        if let previousItem = previousItem, previousItem.translucentDeleted != item.translucentDeleted {
                            deletedNode.layer.animateAlpha(from: previousAlpha, to: alpha, duration: aygDeletedMessageAlphaDuration, timingFunction: CAMediaTimingFunctionName.easeOut.rawValue)
                        }

                        if let markImage = markImage, let bubbleNode = deletedNode as? ChatMessageItemNodeProtocol {
                            let bubbleFrame = bubbleNode.contentFrame()
                            let markSize = markImage.size
                            let markFrame = CGRect(
                                origin: CGPoint(
                                    x: floorToScreenPixels(bubbleFrame.maxX - bubbleTextInsetRight - markTrailingWidth - markSize.width + item.deletedMarkOffsetX),
                                    y: floorToScreenPixels(bubbleFrame.maxY - bubbleTextInsetBottom - dateHeight + (dateHeight - markSize.height) / 2.0)
                                ),
                                size: markSize
                            )

                            strongSelf.deletedMarkNode.image = markImage
                            strongSelf.deletedMarkNode.isHidden = false
                            if strongSelf.deletedMarkNode.supernode !== deletedNode {
                                strongSelf.deletedMarkNode.removeFromSupernode()
                            }
                            // Re-added every pass: the bubble node reorders its own
                            // subnodes as it lays out, and this has to stay on top.
                            deletedNode.addSubnode(strongSelf.deletedMarkNode)
                            strongSelf.deletedMarkNode.frame = markFrame
                        } else {
                            strongSelf.deletedMarkNode.isHidden = true
                        }
                    } else {
                        strongSelf.deletedMarkNode.isHidden = true
                    }

                    if let currentBackgroundNode = currentBackgroundNode, strongSelf.backgroundNode !== currentBackgroundNode {
                        strongSelf.backgroundNode = currentBackgroundNode
                        strongSelf.insertSubnode(currentBackgroundNode, at: 0)
                    }

                    strongSelf.topStripeNode.backgroundColor = item.theme.list.itemBlocksSeparatorColor
                    strongSelf.bottomStripeNode.backgroundColor = item.theme.list.itemBlocksSeparatorColor

                    if strongSelf.topStripeNode.supernode == nil {
                        strongSelf.insertSubnode(strongSelf.topStripeNode, at: 1)
                    }
                    if strongSelf.bottomStripeNode.supernode == nil {
                        strongSelf.insertSubnode(strongSelf.bottomStripeNode, at: 2)
                    }
                    if strongSelf.maskNode.supernode == nil {
                        strongSelf.insertSubnode(strongSelf.maskNode, at: 3)
                    }

                    let hasCorners = itemListHasRoundedBlockLayout(params)
                    var hasTopCorners = false
                    var hasBottomCorners = false
                    switch neighbors.top {
                        case .sameSection(false):
                            strongSelf.topStripeNode.isHidden = true
                        default:
                            hasTopCorners = true
                            strongSelf.topStripeNode.isHidden = hasCorners
                    }
                    let bottomStripeInset: CGFloat
                    let bottomStripeOffset: CGFloat
                    switch neighbors.bottom {
                        case .sameSection(false):
                            bottomStripeInset = 0.0
                            bottomStripeOffset = -separatorHeight
                            strongSelf.bottomStripeNode.isHidden = false
                        default:
                            bottomStripeInset = 0.0
                            bottomStripeOffset = 0.0
                            hasBottomCorners = true
                            strongSelf.bottomStripeNode.isHidden = hasCorners
                    }

                    strongSelf.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(item.componentTheme, top: hasTopCorners, bottom: hasBottomCorners, glass: item.systemStyle == .glass) : nil

                    let backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: contentSize.height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight)))

                    let displayMode: WallpaperDisplayMode
                    if abs(params.availableHeight - params.width) < 100.0, params.availableHeight > 700.0 {
                        displayMode = .halfAspectFill
                    } else {
                        if backgroundFrame.width > backgroundFrame.height * 4.0 {
                            if params.availableHeight < 700.0 {
                                displayMode = .halfAspectFill
                            } else {
                                displayMode = .aspectFill
                            }
                        } else {
                            displayMode = .aspectFill
                        }
                    }

                    if let backgroundNode = strongSelf.backgroundNode {
                        backgroundNode.frame = backgroundFrame.insetBy(dx: 0.0, dy: -100.0)
                        backgroundNode.updateLayout(size: backgroundNode.bounds.size, displayMode: displayMode, transition: .immediate)
                    }
                    strongSelf.maskNode.frame = backgroundFrame.insetBy(dx: params.leftInset, dy: 0.0)
                    strongSelf.topStripeNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: layoutSize.width, height: separatorHeight))
                    strongSelf.bottomStripeNode.frame = CGRect(origin: CGPoint(x: bottomStripeInset, y: contentSize.height + bottomStripeOffset), size: CGSize(width: layoutSize.width - bottomStripeInset, height: separatorHeight))
                }
            })
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}
