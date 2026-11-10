import Foundation

// AYG: unlimited accounts, from Swiftgram.
//
// Telegram-iOS caps the accounts on one device at three, or four once one of them has
// Premium — `maximumNumberOfAccounts` / `maximumPremiumNumberOfAccounts` in AccountUtils,
// and the same two numbers spelled out again at every "Add Account" site. The cap is the
// client's alone: the servers know nothing of it, and every logged-in record is an
// active account however many there are. Swiftgram (Swiftgram/Telegram-iOS,
// `submodules/AccountUtils/Sources/AccountUtils.swift`) raises it to a number nobody
// reaches, Premium or not, and from the seventh account on reminds the user to keep a
// second way into their accounts before the login starts. Both numbers live here, in
// TelegramCore, so every site that gates "Add Account" — Settings, the log-out and
// delete-account option sheets — reads the
// same values without a new module dependency.

public enum AYGAccountLimit {
    /// Swiftgram's `maximumSwiftgramNumberOfAccounts`: the cap, with or without Premium.
    public static let maximum: Int = 500

    /// Swiftgram's `maximumSafeNumberOfAccounts`: past this many accounts, adding
    /// another first shows the `AYGAccountBackupReminder` alert.
    public static let safeMaximum: Int = 6

    /// Whether logging in on top of `accountCount` accounts warrants the reminder.
    public static func needsBackupReminder(accountCount: Int) -> Bool {
        return accountCount + 1 > AYGAccountLimit.safeMaximum
    }
}
