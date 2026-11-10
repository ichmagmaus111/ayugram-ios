// AYG: a copy of SettingsUI's MaximumCacheSizePickerItem — the discrete size
// slider with a label under every stop. It is the exact counterpart of AyuGram
// for Android's `SlideChooseView` (`UItem.asSlideView`), which is what the
// "Max folder size" row is over there.
//
// Copied rather than imported because SettingsUI already depends on AyuGramUI;
// depending on it the other way round is a build cycle. Copied rather than
// generalised upstream so merges from Telegram stay clean.
//
// Three things differ from the original:
//
//   * the stops are passed in as labels instead of being read from a private
//     `maximumCacheSizeValues` table — AyuGram picks its own, and their titles
//     ("300 MB", "16 GB", "No limit") are AyuGram's own strings;
//   * the number of stops is variable. Upstream is hardwired to four; AyuGram
//     shows four, five or six depending on how big the device's volume is, so
//     the label nodes are built per layout instead of in `init`;
//   * `systemStyle` was added, the way AutodownloadSizeLimitItem already has it,
//     so the row can draw glass corners and the 16pt separator inset like the
//     rest of the AyuGram screens.

import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import LegacyComponents
import ItemListUI

public final class AYGSlideChooseItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let systemStyle: ItemListSystemStyle
    let titles: [String]
    let value: Int
    public let sectionId: ItemListSectionId
    let updated: (Int) -> Void

    public init(theme: PresentationTheme, systemStyle: ItemListSystemStyle = .legacy, titles: [String], value: Int, sectionId: ItemListSectionId, updated: @escaping (Int) -> Void) {
        self.theme = theme
        self.systemStyle = systemStyle
        self.titles = titles
        self.value = value
        self.sectionId = sectionId
        self.updated = updated
    }

    public func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = AYGSlideChooseItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))

            node.contentSize = layout.contentSize
            node.insets = layout.insets

            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply() })
                })
            }
        }
    }

    public func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? AYGSlideChooseItemNode {
                let makeLayout = nodeValue.asyncLayout()

                async {
                    let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
                    Queue.mainQueue().async {
                        completion(layout, { _ in
                            apply()
                        })
                    }
                }
            }
        }
    }
}

private final class AYGSlideChooseItemNode: ListViewItemNode {
    private let backgroundNode: ASDisplayNode
    private let topStripeNode: ASDisplayNode
    private let bottomStripeNode: ASDisplayNode
    private let maskNode: ASImageNode

    // AYG: upstream keeps a fixed four of these, made in `init`. The count here
    // depends on the item, so they are made in the layout pass and swapped in.
    private var textNodes: [TextNode] = []
    private var sliderView: TGPhotoEditorSliderView?

    private var item: AYGSlideChooseItem?
    private var layoutParams: ListViewItemLayoutParams?

    init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true

        self.topStripeNode = ASDisplayNode()
        self.topStripeNode.isLayerBacked = true

        self.bottomStripeNode = ASDisplayNode()
        self.bottomStripeNode.isLayerBacked = true

        self.maskNode = ASImageNode()

        super.init(layerBacked: false)
    }

    func updateSliderView() {
        if let sliderView = self.sliderView, let item = self.item {
            let positionsCount = max(2, item.titles.count)
            sliderView.maximumValue = CGFloat(positionsCount - 1)
            sliderView.positionsCount = positionsCount

            sliderView.value = CGFloat(max(0, min(item.titles.count - 1, item.value)))
        }
    }

    override func didLoad() {
        super.didLoad()

        let sliderView = TGPhotoEditorSliderView()
        sliderView.enablePanHandling = true
        sliderView.trackCornerRadius = 2.0
        sliderView.lineSize = 4.0
        sliderView.dotSize = 5.0
        sliderView.minimumValue = 0.0
        sliderView.maximumValue = 3.0
        sliderView.startValue = 0.0
        sliderView.disablesInteractiveTransitionGestureRecognizer = true
        sliderView.positionsCount = 4
        sliderView.useLinesForPositions = true
        if let item = self.item, let params = self.layoutParams {
            sliderView.backgroundColor = item.theme.list.itemBlocksBackgroundColor
            sliderView.backColor = item.theme.list.itemSwitchColors.frameColor
            sliderView.startColor = item.theme.list.itemSwitchColors.frameColor
            sliderView.trackColor = item.theme.list.itemAccentColor
            sliderView.knobImage = PresentationResourcesItemList.knobImage(item.theme)

            sliderView.frame = CGRect(origin: CGPoint(x: params.leftInset + 15.0, y: 37.0), size: CGSize(width: params.width - params.leftInset - params.rightInset - 15.0 * 2.0, height: 44.0))
            sliderView.hitTestEdgeInsets = UIEdgeInsets(top: -sliderView.frame.minX, left: 0.0, bottom: 0.0, right: -sliderView.frame.minX)
        }
        self.view.addSubview(sliderView)
        sliderView.addTarget(self, action: #selector(self.sliderValueChanged), for: .valueChanged)
        self.sliderView = sliderView

        self.updateSliderView()
    }

    func asyncLayout() -> (_ item: AYGSlideChooseItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        let currentItem = self.item
        let currentTextNodes = self.textNodes

        return { [weak self] item, params, neighbors in
            var themeUpdated = false
            if currentItem?.theme !== item.theme {
                themeUpdated = true
            }

            let contentSize: CGSize
            let insets: UIEdgeInsets
            let separatorHeight = UIScreenPixel
            let separatorRightInset: CGFloat = item.systemStyle == .glass ? 16.0 : 0.0

            var textLayouts: [TextNodeLayout] = []
            var textApplies: [() -> TextNode] = []

            for i in 0 ..< item.titles.count {
                // AYG: reuse the node already on screen at this position when
                // there is one, otherwise TextNode.asyncLayout makes a fresh one.
                let makeTextLayout = TextNode.asyncLayout(i < currentTextNodes.count ? currentTextNodes[i] : nil)
                let (textLayout, textApply) = makeTextLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.titles[i], font: Font.regular(13.0), textColor: item.theme.list.itemSecondaryTextColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: params.width, height: CGFloat.greatestFiniteMagnitude), alignment: .center, lineSpacing: 0.0, cutout: nil, insets: UIEdgeInsets()))
                textLayouts.append(textLayout)
                textApplies.append(textApply)
            }

            contentSize = CGSize(width: params.width, height: 88.0)
            insets = itemListNeighborsGroupedInsets(neighbors, params)

            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)
            let layoutSize = layout.size

            return (layout, { [weak self] in
                if let strongSelf = self {
                    strongSelf.item = item
                    strongSelf.layoutParams = params

                    strongSelf.backgroundNode.backgroundColor = item.theme.list.itemBlocksBackgroundColor
                    strongSelf.topStripeNode.backgroundColor = item.theme.list.itemBlocksSeparatorColor
                    strongSelf.bottomStripeNode.backgroundColor = item.theme.list.itemBlocksSeparatorColor

                    if strongSelf.backgroundNode.supernode == nil {
                        strongSelf.insertSubnode(strongSelf.backgroundNode, at: 0)
                    }
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

                    strongSelf.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(item.theme, top: hasTopCorners, bottom: hasBottomCorners, glass: item.systemStyle == .glass) : nil

                    strongSelf.backgroundNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: contentSize.height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight)))
                    strongSelf.maskNode.frame = strongSelf.backgroundNode.frame.insetBy(dx: params.leftInset, dy: 0.0)
                    strongSelf.topStripeNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: layoutSize.width, height: separatorHeight))
                    strongSelf.bottomStripeNode.frame = CGRect(origin: CGPoint(x: bottomStripeInset, y: contentSize.height + bottomStripeOffset), size: CGSize(width: layoutSize.width - bottomStripeInset - separatorRightInset, height: separatorHeight))

                    var updatedTextNodes: [TextNode] = []
                    for apply in textApplies {
                        updatedTextNodes.append(apply())
                    }
                    for textNode in strongSelf.textNodes where !updatedTextNodes.contains(where: { $0 === textNode }) {
                        textNode.removeFromSupernode()
                    }
                    for textNode in updatedTextNodes where textNode.supernode == nil {
                        textNode.isUserInteractionEnabled = false
                        textNode.displaysAsynchronously = false
                        strongSelf.addSubnode(textNode)
                    }
                    strongSelf.textNodes = updatedTextNodes

                    if updatedTextNodes.count > 1 {
                        let delta = (params.width - params.leftInset - params.rightInset - 18.0 * 2.0) / CGFloat(updatedTextNodes.count - 1)
                        for i in 0 ..< updatedTextNodes.count {
                            let textSize = textLayouts[i].size

                            var position = params.leftInset + 18.0 + delta * CGFloat(i)
                            if i == updatedTextNodes.count - 1 {
                                position -= textSize.width
                            } else if i > 0 {
                                position -= textSize.width / 2.0
                            }

                            updatedTextNodes[i].frame = CGRect(origin: CGPoint(x: position, y: 15.0), size: textSize)
                        }
                    } else if let textNode = updatedTextNodes.first {
                        textNode.frame = CGRect(origin: CGPoint(x: params.leftInset + 18.0, y: 15.0), size: textLayouts[0].size)
                    }

                    if let sliderView = strongSelf.sliderView {
                        if themeUpdated {
                            sliderView.backgroundColor = item.theme.list.itemBlocksBackgroundColor
                            sliderView.backColor = item.theme.list.itemSwitchColors.frameColor
                            sliderView.startColor = item.theme.list.itemSwitchColors.frameColor
                            sliderView.trackColor = item.theme.list.itemAccentColor
                            sliderView.knobImage = PresentationResourcesItemList.knobImage(item.theme)
                        }

                        sliderView.frame = CGRect(origin: CGPoint(x: params.leftInset + 15.0, y: 37.0), size: CGSize(width: params.width - params.leftInset - params.rightInset - 15.0 * 2.0, height: 44.0))
                        sliderView.hitTestEdgeInsets = UIEdgeInsets(top: -sliderView.frame.minX, left: 0.0, bottom: 0.0, right: -sliderView.frame.minX)

                        strongSelf.updateSliderView()
                    }
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

    @objc private func sliderValueChanged() {
        guard let sliderView = self.sliderView, let item = self.item else {
            return
        }

        let position = max(0, min(item.titles.count - 1, Int(sliderView.value)))
        item.updated(position)
    }
}
