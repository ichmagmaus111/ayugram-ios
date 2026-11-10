// AYG: the "this will not burn" notices AyuGram shows for kept one-time media.
//
// Android raises them as tooltips over the one-time viewer; the four strings are
// `OncePhotoMessageNote`, `OnceVideoMessageNote`, `ExpiringVideoMessageNote` (round
// video) and `ExpiringVoiceMessageNote`, verbatim from `docs/AYGAndroidStrings.xml`.
// Our equivalent is an `UndoOverlayController`, the same thing every other AYG
// screen uses for a transient message.

import Foundation
import UIKit
import Display
import TelegramCore
import Postbox
import AccountContext
import PresentationDataUtils
import UndoUI

private var aygOncePhotoNote: String { aygString("OncePhotoMessageNote") }
private var aygOnceVideoNote: String { aygString("OnceVideoMessageNote") }
private var aygExpiringVideoMessageNote: String { aygString("ExpiringVideoMessageNote") }
private var aygExpiringVoiceMessageNote: String { aygString("ExpiringVoiceMessageNote") }

/// Starts listening for kept one-time media being revealed, and raises AyuGram's
/// notice when it is.
///
/// One observer for the whole app rather than a call at each open site: a photo or
/// video reveals itself by being opened, a voice message or a round video by being
/// played, and the only place all four meet is the consume path in TelegramCore —
/// which cannot reach a window, so it posts instead.
public func aygObserveViewOnceNotices(context: AccountContext) {
    guard aygViewOnceNoticeObserver == nil else {
        return
    }
    aygViewOnceNoticeObserver = NotificationCenter.default.addObserver(
        forName: AYGViewOnceManager.mediaRevealedNotification,
        object: nil,
        queue: .main
    ) { [weak context] notification in
        guard let context else {
            return
        }
        guard let rawKind = notification.userInfo?[AYGViewOnceManager.mediaRevealedKindKey] as? String,
              let kind = AYGViewOnceKind(rawValue: rawKind),
              let messageKey = notification.userInfo?[AYGViewOnceManager.mediaRevealedMessageKey] as? String else {
            return
        }
        // The countdown never starts for kept media, so without this every re-open of
        // the same photo would raise the same notice again.
        if aygShownViewOnceNotices.contains(messageKey) {
            return
        }
        aygShownViewOnceNotices.insert(messageKey)

        let text: String
        switch kind {
        case .photo:
            text = aygOncePhotoNote
        case .video:
            text = aygOnceVideoNote
        case .roundVideo:
            text = aygExpiringVideoMessageNote
        case .voice:
            text = aygExpiringVoiceMessageNote
        }

        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let controller = UndoOverlayController(
            presentationData: presentationData,
            content: .info(title: nil, text: text, timeout: nil, customUndoText: nil),
            elevatedLayout: false,
            action: { _ in return true }
        )
        context.sharedContext.mainWindow?.present(controller, on: .root)
    }
}

private var aygViewOnceNoticeObserver: NSObjectProtocol?

/// Main-thread only, which the observer above is.
private var aygShownViewOnceNotices = Set<String>()
