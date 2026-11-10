import Foundation
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import AlertComponent
import UndoUI

// AYG: "Story Ghost Mode Alert" — AyuGram's `SuggestGhostModeBeforeViewingStory`.
//
// Ported from `org.telegram.ui.Stories.StoryViewer.open(...)`, which is the one place
// AyuGram for Android gates. Every `StoryViewer.open` overload funnels into the nine
// argument one, and it reads:
//
//     if (!isSuggestGhostModeBeforeViewingStory() || !isSendReadStoryPackets() || context == null) {
//         openInner(...);
//         return;
//     }
//     builder.setTitle(SuggestGhostModeTitle);
//     builder.setMessage(replaceTags(SuggestGhostModeStoryText));
//     builder.setNegativeButton(SuggestGhostModeStoryActionTextNo, -> openInner(...));
//     builder.setPositiveButton(SuggestGhostModeStoryActionTextYes, -> {
//         setGhostMode(true, BulletinFactory.global());
//         disableGhostModeAfterClose = true;
//         openInner(...);
//     });
//     fragment.showDialog(builder.create());
//
// Four things fall out of that, and all four are what this file implements:
//
//   * **Both answers open the story.** "No" is not a cancel; it is "open it without Ghost
//     Mode". Only dismissing the dialog by tapping outside leaves the story unopened,
//     which is what `cancelled` is for.
//   * **"Yes" turns on the whole of Ghost Mode**, not just the stories option —
//     `setGhostMode` drives all five options, skipping the ones the user has locked.
//   * **The viewer turns it back off when it closes** (`disableGhostModeAfterClose`,
//     honoured in `StoryViewer.close`). `AYGStoryGhostModeRevert` is that flag; the
//     `StoryContainerScreen` opened right after the alert claims it and performs it when
//     it goes away.
//   * **Nothing is remembered.** There is no "don't ask again" and no per-story record:
//     the alert is shown every time the viewer is opened. Once per *opening*, not once
//     per story — moving between stories inside an open viewer never calls `open` again.
//
// `AYGGhostModeManager.shouldSuggestGhostModeBeforeStory` is already
// `isSuggestGhostModeBeforeViewingStory() && isSendReadStoryPackets()`, so it is the
// whole of Android's condition on its own.

/// Ask before the story viewer opens, then run `open`.
///
/// Calls `open()` synchronously when the alert is not wanted, so a caller that does not
/// need the alert behaves exactly as it did before this existed.
///
/// `cancelled` runs instead of `open` when the user dismisses the alert without
/// answering. Pass it wherever the caller has already mutated the screen it is
/// transitioning from — a hidden avatar, a hidden gallery source — so that path can be
/// put back.
public func aygSuggestGhostModeBeforeStory(
    context: AccountContext,
    cancelled: (() -> Void)? = nil,
    open: @escaping () -> Void
) {
    guard AYGGhostModeManager.shared.shouldSuggestGhostModeBeforeStory(forAccount: context.account.peerId) else {
        open()
        return
    }
    guard let window = context.sharedContext.mainWindow else {
        // Android's `context == null` arm: no way to put a dialog on screen, so open.
        open()
        return
    }

    var didAnswer = false

    let controller = textAlertController(
        context: context,
        title: aygGhostModeAlertTitle,
        text: aygGhostModeStoryAlertText,
        actions: [
            TextAlertAction(type: .genericAction, title: aygGhostModeStoryAlertNo, action: {
                didAnswer = true
                open()
            }),
            TextAlertAction(type: .defaultAction, title: aygGhostModeStoryAlertYes, action: {
                didAnswer = true
                aygEnableGhostModeForStory(context: context)
                open()
            })
        ],
        parseMarkdown: true
    )

    // Android's dialog is cancelable, and cancelling it does not open the story. The
    // caller may already have hidden the view it was going to transition from, so tell it.
    (controller as? AlertScreen)?.dismissed = { _ in
        if !didAnswer {
            cancelled?()
        }
    }

    window.present(controller, on: .root)
}

// MARK: - Strings
//
// AyuGram ships its own English strings as a plain asset and looks them up by name, so
// these are the literal values out of `ayu.xml` (see `docs/AYGAndroidStrings.xml`). The
// `**` is Android's bold markup and is also what `AlertScreen` parses.

private var aygGhostModeAlertTitle: String { aygString("SuggestGhostModeTitle") }
private var aygGhostModeStoryAlertText: String { aygString("SuggestGhostModeStoryText") }
private var aygGhostModeStoryAlertYes: String { aygString("SuggestGhostModeStoryActionTextYes") }
private var aygGhostModeStoryAlertNo: String { aygString("SuggestGhostModeStoryActionTextNo") }
private var aygGhostModeEnabledText: String { aygString("GhostModeEnabled") }
private var aygGhostModeDisabledText: String { aygString("GhostModeDisabled") }

// MARK: - Turning Ghost Mode on and back off

/// The record the alert writes to: the global one unless the Ghost Mode screen's account
/// picker has been switched to per-account settings. Same resolution
/// `AYGGhostModeController` uses, so the alert and the screen never edit different rows.
private func aygGhostModeTargetRecord(context: AccountContext) -> EnginePeer.Id? {
    return AYGGhostModeManager.shared.useGlobalSettings ? nil : context.account.peerId
}

private func aygEnableGhostModeForStory(context: AccountContext) {
    let accountPeerId = aygGhostModeTargetRecord(context: context)
    let previousSettings = AYGGhostModeManager.shared.storedSettings(forAccount: accountPeerId)

    AYGGhostModeManager.shared.updateStoredSettings(forAccount: accountPeerId) { settings in
        settings.setGhostMode(true)
    }
    aygPresentGhostModeBulletin(context: context)

    AYGStoryGhostModeRevert.arm(AYGStoryGhostModeRevert(
        context: context,
        accountPeerId: accountPeerId,
        previousSettings: previousSettings
    ))
}

/// AyuGram's `BulletinFactory.global()` toast, which `setGhostMode` shows on both
/// transitions. Like Android's, it reports the state the account is actually in *after*
/// the write rather than the direction of the write — restoring a record that still has
/// options on says so. Presented on the window rather than on a controller because the
/// story viewer is going up (or coming down) at the same moment.
private func aygPresentGhostModeBulletin(context: AccountContext) {
    guard let window = context.sharedContext.mainWindow else {
        return
    }
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let content: UndoOverlayContent
    if AYGGhostModeManager.shared.isGhostModeActive(forAccount: context.account.peerId) {
        content = .succeed(text: aygGhostModeEnabledText, timeout: nil, customUndoText: nil)
    } else {
        content = .info(title: nil, text: aygGhostModeDisabledText, timeout: nil, customUndoText: nil)
    }
    window.present(
        UndoOverlayController(
            presentationData: presentationData,
            content: content,
            elevatedLayout: false,
            action: { _ in return true }
        ),
        on: .root
    )
}

/// Android's `StoryViewer.disableGhostModeAfterClose`, as an object so it can be handed
/// to the screen that has to honour it.
///
/// One deliberate difference: Android reverts with `setGhostMode(false)`, which turns
/// *every* option off — including ones the user had on before the alert appeared. This
/// restores the five options to exactly what they were instead, so answering "Yes" can
/// never leave the user with less Ghost Mode than they started with.
final class AYGStoryGhostModeRevert {
    /// Armed by the alert, claimed by the next `StoryContainerScreen` to be built. The
    /// handshake is main-thread only: the alert's action, the screen's `init` and the
    /// expiry below all run there.
    private static var pending: AYGStoryGhostModeRevert?

    private let context: AccountContext
    private let accountPeerId: EnginePeer.Id?
    private let previousSettings: AYGGhostModeSettings
    private var isPerformed: Bool = false

    init(context: AccountContext, accountPeerId: EnginePeer.Id?, previousSettings: AYGGhostModeSettings) {
        self.context = context
        self.accountPeerId = accountPeerId
        self.previousSettings = previousSettings
    }

    static func arm(_ token: AYGStoryGhostModeRevert) {
        AYGStoryGhostModeRevert.pending = token

        // An open path can still bail after the alert is answered — no slice to show, a
        // dead parent controller — and then nothing ever claims this. Drop it rather than
        // leave it armed for whatever story is opened next, and drop it *without*
        // reverting: the user did ask for Ghost Mode, so leaving it on is the safe half.
        Queue.mainQueue().after(20.0, {
            if AYGStoryGhostModeRevert.pending === token {
                AYGStoryGhostModeRevert.pending = nil
            }
        })
    }

    static func claimPending() -> AYGStoryGhostModeRevert? {
        let value = AYGStoryGhostModeRevert.pending
        AYGStoryGhostModeRevert.pending = nil
        return value
    }

    func perform() {
        if self.isPerformed {
            return
        }
        self.isPerformed = true

        let context = self.context
        let accountPeerId = self.accountPeerId
        let previousSettings = self.previousSettings

        // Called from `deinit`, so hop to the main queue before touching UI.
        Queue.mainQueue().async {
            AYGGhostModeManager.shared.updateStoredSettings(forAccount: accountPeerId) { settings in
                for option in AYGGhostModeOption.allCases {
                    settings.setSelected(previousSettings.isSelected(option), for: option)
                }
            }
            aygPresentGhostModeBulletin(context: context)
        }
    }
}
