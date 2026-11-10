import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import MergeLists
import AppBundle

private enum AYGSettingsSection: Int32 {
    case header
    case categories
    case links
}

private final class AYGSettingsArguments {
    let openCategory: (AYGSettingsCategory) -> Void
    let openLink: (AYGSettingsLink) -> Void

    init(openCategory: @escaping (AYGSettingsCategory) -> Void, openLink: @escaping (AYGSettingsLink) -> Void) {
        self.openCategory = openCategory
        self.openLink = openLink
    }
}

private enum AYGSettingsEntry: ItemListNodeEntry {
    case header(String, String)
    case categoriesHeader(String)
    case category(AYGSettingsCategory)
    case linksHeader(String)
    case link(AYGSettingsLink)

    var section: ItemListSectionId {
        switch self {
        case .header:
            return AYGSettingsSection.header.rawValue
        case .categoriesHeader, .category:
            return AYGSettingsSection.categories.rawValue
        case .linksHeader, .link:
            return AYGSettingsSection.links.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .header:
            return 0
        case .categoriesHeader:
            return 1
        case let .category(category):
            return 2 + Int32(category.rawValue)
        case .linksHeader:
            return 100
        case let .link(link):
            return 101 + Int32(link.rawValue)
        }
    }

    static func <(lhs: AYGSettingsEntry, rhs: AYGSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AYGSettingsArguments
        switch self {
        case let .header(title, version):
            return AYGHeaderItem(presentationData: presentationData, title: title, version: version, sectionId: self.section)
        case let .categoriesHeader(text), let .linksHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .category(category):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                // AYG: .glass gives the 26pt block corners the rest of Settings uses;
                // the default .legacy draws 11pt ones and looks foreign next to them.
                systemStyle: .glass,
                icon: category.icon(theme: presentationData.theme),
                title: category.title,
                label: "",
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .none,
                action: {
                    arguments.openCategory(category)
                }
            )
        case let .link(link):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: link.icon(theme: presentationData.theme),
                title: link.title,
                label: link.value,
                labelStyle: .coloredText(presentationData.theme.list.itemAccentColor),
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .none,
                action: {
                    arguments.openLink(link)
                }
            )
        }
    }
}

private func aygSettingsControllerEntries(version: String) -> [AYGSettingsEntry] {
    var entries: [AYGSettingsEntry] = [
        .header(aygAppName, version),
        .categoriesHeader(aygString("CategoriesHeader").uppercased())
    ]
    for category in AYGSettingsCategory.allCases {
        entries.append(.category(category))
    }
    entries.append(.linksHeader(aygString("LinksHeader").uppercased()))
    for link in AYGSettingsLink.allCases {
        entries.append(.link(link))
    }
    return entries
}

// AYG: root screen of the AyuGram section in Settings.
public func aygSettingsController(context: AccountContext) -> ViewController {
    var pushImpl: ((ViewController) -> Void)?

    var getNavigationControllerImpl: (() -> NavigationController?)?

    let arguments = AYGSettingsArguments(openCategory: { category in
        pushImpl?(aygCategoryController(context: context, category: category))
    }, openLink: { link in
        if let username = link.username {
            // AYG: resolve the username and push the chat ourselves.
            //
            // openExternalUrl routes t.me links through navigateToChatController with
            // the default `keepStack: .default`, which DROPS everything above the chat
            // list — so swiping back from the channel landed in the root of Settings
            // instead of here. Pushing onto our own navigation stack keeps this screen
            // underneath, which is what Settings' own "Ask a Question" row does too.
            let _ = (context.engine.peers.resolvePeerByName(name: username, referrer: nil)
            |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
                switch result {
                case .progress:
                    return .complete()
                case let .result(peer):
                    return .single(peer)
                }
            }
            |> take(1)
            |> deliverOnMainQueue).startStandalone(next: { peer in
                guard let peer else {
                    return
                }
                pushImpl?(context.sharedContext.makeChatController(context: context, chatLocation: .peer(id: peer.id), subject: nil, botStart: nil, mode: .standard(.default), params: nil))
            })
        } else if let url = link.url {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            context.sharedContext.openExternalUrl(
                context: context,
                urlContext: .generic,
                url: url,
                forceExternal: false,
                presentationData: presentationData,
                navigationController: getNavigationControllerImpl?(),
                dismissInput: {}
            )
        }
    })

    let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""

    let signal = context.sharedContext.presentationData
    |> deliverOnMainQueue
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(""),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: aygSettingsControllerEntries(version: version),
            style: .blocks,
            animateChanges: false
        )

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    getNavigationControllerImpl = { [weak controller] in
        return controller?.navigationController as? NavigationController
    }
    return controller
}
