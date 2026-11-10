// AYG: keeps `aygString` on Telegram's language rather than the system's.
//
// The lookup itself lives in TelegramCore (`AYGShared/AYGStrings.swift`) so that modules
// which must not depend on AyuGramUI — the login screen, the story viewer — can still
// translate. Only the subscription needs an `AccountContext`, so only the subscription
// is here.

import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext

/// Called once from `TelegramRootController.addRootControllers`; the subscription lives
/// for the process, which is what a language setting wants.
public func aygObserveStringsLanguage(context: AccountContext) {
    guard aygStringsLanguageDisposable == nil else {
        return
    }
    aygStringsLanguageDisposable = (context.sharedContext.presentationData
    |> map { $0.strings.baseLanguageCode }
    |> distinctUntilChanged
    |> deliverOnMainQueue).start(next: { code in
        aygSetStringsLanguage(code)
    })
}

private var aygStringsLanguageDisposable: Disposable?
