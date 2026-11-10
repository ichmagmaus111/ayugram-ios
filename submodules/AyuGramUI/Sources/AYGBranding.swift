import Foundation
import TelegramCore

// AYG: user-visible name of the fork. Single source of truth for every place
// the app names itself in the UI.
public let aygAppName: String = "AyuGram"

// AYG: title of the Settings row that opens the AyuGram screen, and of that
// screen's navigation bar. `AyuPreferences` is what Android calls the same screen.
public var aygSettingsRowTitle: String { aygString("AyuPreferences") }

// AYG: the message context-menu entry that sends a read receipt Ghost Mode would
// otherwise suppress.
public var aygMarkAsReadMenuText: String { aygString("AYGMarkAsReadMenuText") }

// AYG: `ExpireMediaContextMenuText` — spends a view-once photo the fork was holding.
public var aygBurnViewOnceMenuText: String { aygString("ExpireMediaContextMenuText") }
