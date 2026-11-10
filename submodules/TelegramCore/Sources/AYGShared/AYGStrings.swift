import Foundation

// AYG: AyuGram's own translations.
//
// AyuGram for Android keeps its strings in `assets/ayu_locales/values-*/ayu.xml` and
// looks them up by name at runtime; the fork's iOS side does the same thing with the
// same key names, out of flat JSON in `Telegram/Telegram-iOS/AYGLocales/*.json`. Keeping
// the keys identical to the APK's is what makes any string traceable back to its origin.
//
// English and Russian are maintained by hand and are the two complete languages: every
// string this fork can put on screen has an entry in both. The remaining files came from
// AyuGram's Crowdin export and cover only the keys AyuGram itself has — anything this
// fork added falls back to English there, which is the normal behaviour for a partially
// translated app.
//
// Deliberately *not* `.lproj`/`NSLocalizedString`: `AppStringResources` in
// `Telegram/BUILD` bundles a real `en.lproj` plus empty placeholders for every other
// language, because Telegram downloads the rest at runtime. Slotting AyuGram's strings
// into that scheme would mean either fighting the downloader or shipping the one language
// that is not downloaded.
//
// This lives in TelegramCore rather than in AyuGramUI because the strings are needed from
// modules that must not depend on AyuGramUI — the login screen (AuthorizationUI) and the
// story viewer among them. Nothing here touches UIKit, so the Mac codebase's ban on
// UI frameworks in TelegramCore holds.

/// The AyuGram string for `key`, in the app's current language.
///
/// Falls back to English, then to the key itself — a missing key shows as its own name
/// rather than as an empty row, which is what you want when a translation lands late.
public func aygString(_ key: String) -> String {
    return AYGStrings.shared.value(for: key) ?? key
}

/// `aygString`, with an explicit fallback for keys with no entry at all.
public func aygString(_ key: String, fallback: String) -> String {
    return AYGStrings.shared.value(for: key) ?? fallback
}

/// The AyuGram string for `key`, with `%1$@`-style placeholders filled in.
///
/// Android writes its placeholders `%1$s`; Foundation spells the same thing `%1$@`, so
/// both are accepted and normalised here. Positional placeholders are the point — a
/// translation is free to reorder them, and several already do.
/// Spelled with a mandatory first argument rather than a bare variadic so that
/// `aygString("Key")` cannot be ambiguous between this and the no-argument overload.
public func aygString(_ key: String, _ firstArgument: CVarArg, _ otherArguments: CVarArg...) -> String {
    return aygFormat(aygString(key), [firstArgument] + otherArguments)
}

/// The plural form of `key` for `count`, with `%1$d` filled in.
///
/// Android splits a quantity string into `Key_zero` … `Key_other`; the export keeps that
/// shape, so the category is chosen here and the suffix appended. `_other` is the
/// fallback, which is what every language always has.
public func aygPluralString(_ key: String, _ count: Int) -> String {
    let language = AYGStrings.currentLanguage()
    for suffix in AYGStrings.pluralSuffixes(count: count, language: language) {
        if let value = AYGStrings.shared.value(for: key + suffix) {
            return aygFormat(value, [count])
        }
    }
    return key
}

/// Points `aygString` at `code`, which is Telegram's language rather than the system's.
///
/// Called from `aygObserveStringsLanguage` in AyuGramUI, which is where the
/// `presentationData` subscription can live.
public func aygSetStringsLanguage(_ code: String) {
    AYGStrings.languageLock.lock()
    let normalized = AYGStrings.normalize(code)
    let changed = AYGStrings.overrideLanguage != normalized
    AYGStrings.overrideLanguage = normalized
    AYGStrings.languageLock.unlock()
    if changed {
        AYGStrings.shared.invalidate()
    }
}

private func aygFormat(_ template: String, _ arguments: [CVarArg]) -> String {
    guard !arguments.isEmpty else {
        return template
    }
    return String(format: template.replacingOccurrences(of: "$s", with: "$@"), arguments: arguments)
}

private final class AYGStrings {
    static let shared = AYGStrings()

    private let lock = NSLock()
    private var active: [String: String]?
    private var english: [String: String]?
    private var loadedLanguage: String?

    private init() {}

    func value(for key: String) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }

        let language = AYGStrings.currentLanguage()
        if self.loadedLanguage != language {
            self.loadedLanguage = language
            self.active = language == "en" ? nil : AYGStrings.load(language)
            if self.english == nil {
                self.english = AYGStrings.load("en")
            }
        }

        if let value = self.active?[key] {
            return value
        }
        return self.english?[key]
    }

    func invalidate() {
        self.lock.lock()
        self.loadedLanguage = nil
        self.active = nil
        self.lock.unlock()
    }

    fileprivate static let languageLock = NSLock()
    fileprivate static var overrideLanguage: String?

    /// The language the user is actually reading the app in.
    ///
    /// Telegram's language is its own setting, not the system's — someone running an
    /// English phone with Telegram in Russian must get Russian here. So the override is
    /// fed from `presentationData.strings.baseLanguageCode`, and the system language is
    /// only used before that subscription has delivered (a window of milliseconds at
    /// launch) or in an extension, which has no presentation data of its own.
    fileprivate static func currentLanguage() -> String {
        AYGStrings.languageLock.lock()
        let override = AYGStrings.overrideLanguage
        AYGStrings.languageLock.unlock()
        return override ?? AYGStrings.normalize(Locale.preferredLanguages.first ?? "en")
    }

    /// Telegram's codes and Apple's disagree in the same two places AyuGram's own file
    /// names do — Chinese script variants and Hebrew's legacy code.
    fileprivate static func normalize(_ code: String) -> String {
        let lowered = code.lowercased()
        if lowered.hasPrefix("zh") {
            if lowered.contains("hant") || lowered.contains("tw") || lowered.contains("hk") {
                return "zh-TW"
            }
            return "zh-CN"
        }
        let base = String(lowered.split(separator: "-").first ?? "en")
        // `iw` is Hebrew's pre-1989 code; Android still files it that way, Apple does not.
        return base == "iw" ? "he" : base
    }

    /// The CLDR plural categories to try, most specific first.
    ///
    /// Only the two hand-maintained languages need to be right: English's one/other, and
    /// the Slavic one/few/many that Russian, Ukrainian and Belarusian share. Everything
    /// else gets the English rule and lands on `_other`, which is the correct form for a
    /// language whose translation is missing anyway.
    fileprivate static func pluralSuffixes(count: Int, language: String) -> [String] {
        switch language {
        case "ru", "uk", "be":
            let mod10 = abs(count) % 10
            let mod100 = abs(count) % 100
            if mod10 == 1 && mod100 != 11 {
                return ["_one", "_other"]
            } else if (2 ... 4).contains(mod10) && !(12 ... 14).contains(mod100) {
                return ["_few", "_other"]
            } else {
                return ["_many", "_other"]
            }
        default:
            return count == 1 ? ["_one", "_other"] : ["_other", "_one"]
        }
    }

    private static func load(_ language: String) -> [String: String]? {
        // AYG: bundled structured, under `Telegram-iOS/AYGLocales/`.
        guard let url = Bundle.main.url(forResource: language, withExtension: "json", subdirectory: "Telegram-iOS/AYGLocales"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return parsed
    }
}
