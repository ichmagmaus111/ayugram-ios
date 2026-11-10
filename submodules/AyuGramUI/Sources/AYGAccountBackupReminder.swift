import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import AccountContext

// AYG: Swiftgram's reminder before a login past `AYGAccountLimit.safeMaximum`.
//
// The seventh account is where Swiftgram stops to say "keep a SIM or another session
// logged in": the more accounts on one device, the likelier that one of them has no other
// way back in. The alert is Telegram's own "Warning!" title over the fork's string, with a
// single OK that starts the login — Swiftgram's `Auth.AccountBackupReminder` alert, which
// it spells out at each of its three sites; here it is built once for the same three
// (Settings, the Log Out options, the Delete Account options).

/// The reminder to show before adding an account on top of `accountCount`, or nil when
/// there is nothing to warn about yet and the login can start straight away.
///
/// `proceed` starts the login; it runs when the alert's OK is tapped.
public func aygAccountBackupReminderController(
    context: AccountContext,
    updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)? = nil,
    accountCount: Int,
    proceed: @escaping () -> Void
) -> ViewController? {
    guard AYGAccountLimit.needsBackupReminder(accountCount: accountCount) else {
        return nil
    }
    let presentationData = updatedPresentationData?.initial ?? context.sharedContext.currentPresentationData.with { $0 }
    return textAlertController(
        context: context,
        updatedPresentationData: updatedPresentationData,
        title: presentationData.strings.ChatList_DeleteSavedMessagesConfirmationTitle,
        text: aygString("AYGAccountBackupReminder"),
        actions: [
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: proceed)
        ],
        dismissOnOutsideTap: false
    )
}
