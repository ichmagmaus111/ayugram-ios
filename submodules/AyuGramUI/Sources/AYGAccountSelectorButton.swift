import Foundation
import UIKit
import Display
import AsyncDisplayKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import AvatarNode
import AppBundle

// AYG: the "all accounts" mark, drawn when Ghost Mode is being edited globally.
// AyuGram for Android shows a filled circle with a people glyph here.
private func aygGlobalAccountsImage(color: UIColor) -> UIImage? {
    return generateImage(CGSize(width: 30.0, height: 30.0), contextGenerator: { size, context in
        let bounds = CGRect(origin: CGPoint(), size: size)
        context.clear(bounds)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: bounds)

        if let image = UIImage(bundleImageName: "Item List/Icons/Group"), let cgImage = image.cgImage {
            let imageSize = CGSize(width: 18.0, height: 18.0)
            let imageRect = CGRect(origin: CGPoint(x: (bounds.width - imageSize.width) / 2.0, y: (bounds.height - imageSize.height) / 2.0), size: imageSize)
            context.saveGState()
            context.clip(to: imageRect, mask: cgImage)
            context.setFillColor(UIColor.white.cgColor)
            context.fill(imageRect)
            context.restoreGState()
        }
    })
}

// AYG: navigation-bar button showing which account Ghost Mode is being edited for.
//
// Reuse ONE instance across state updates: `ItemListNavigationButtonContent.node`
// compares by identity, so handing back a fresh node every time would rebuild the
// bar button on every keystroke of state. The tap is wired through
// `ItemListNavigationButton.action`, not a gesture here — that is how
// `UIBarButtonItem(customDisplayNode:)` is driven.
public final class AYGAccountSelectorButtonNode: ASDisplayNode {
    private let avatarNode: AvatarNode
    private let globalIconNode: ASImageNode

    public override init() {
        self.avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 13.0))
        self.globalIconNode = ASImageNode()
        self.globalIconNode.displaysAsynchronously = false
        self.globalIconNode.displayWithoutProcessing = true

        super.init()

        let size = CGSize(width: 30.0, height: 30.0)
        self.frame = CGRect(origin: CGPoint(), size: size)
        self.avatarNode.frame = CGRect(origin: CGPoint(), size: size)
        self.globalIconNode.frame = CGRect(origin: CGPoint(), size: size)

        self.addSubnode(self.avatarNode)
        self.addSubnode(self.globalIconNode)
    }


    // AYG: a node used as a bar button MUST report its size here. Without it
    // ASDisplayNode hands the navigation bar an unconstrained size and the button
    // stretches across the whole bar, swallowing the title.
    public override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        return CGSize(width: 30.0, height: 30.0)
    }

    // `peer == nil` means "Global Settings".
    public func update(context: AccountContext, theme: PresentationTheme, peer: EnginePeer?) {
        if let peer {
            self.avatarNode.isHidden = false
            self.globalIconNode.isHidden = true
            self.avatarNode.setPeer(
                accountPeerId: context.account.peerId,
                postbox: context.account.postbox,
                network: context.account.network,
                contentSettings: context.currentContentSettings.with { $0 },
                theme: theme,
                peer: peer,
                displayDimensions: CGSize(width: 30.0, height: 30.0)
            )
        } else {
            self.avatarNode.isHidden = true
            self.globalIconNode.isHidden = false
            self.globalIconNode.image = aygGlobalAccountsImage(color: theme.list.itemAccentColor)
        }
    }
}
