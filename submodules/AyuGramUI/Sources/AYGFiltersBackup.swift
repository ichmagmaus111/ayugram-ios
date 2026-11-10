import Foundation
import SwiftSignalKit
import TelegramCore

// AYG: the filter import/export format, decompiled from AyuGram for Android's
// `com.radolyn.ayugram.utils.filters.AyuFilterUtils` (`export`, `prepareChanges`,
// `applyChanges`) so that a backup written here is byte-for-byte what Android
// writes, and a backup written by Android parses here.
//
// Android serialises `AyuFilterUtils.Backup` with
// `new GsonBuilder().setPrettyPrinting().serializeNulls().create()`, so three
// things about Gson are load-bearing and reproduced below:
//
//  * field order is `Class.getDeclaredFields()` order, which on ART is the dex
//    order — fields sorted by name. That is why `exclusions` comes before
//    `filters` and `version` comes last, and why a `RegexFilter` starts at
//    `caseInsensitive`;
//  * `serializeNulls()` means `removeExclusions` / `removeFiltersById`, which
//    `export()` never fills in, are written as literal `null`;
//  * `GsonBuilder` leaves HTML escaping ON, so `<`, `>`, `&`, `=` and `'` are
//    written as the escapes < > & = '. Regular
//    expressions are full of those, so getting this wrong would produce a file
//    that only looks right.
//
// `UUID.toString()` is lowercase in Java; `UUID.uuidString` is uppercase in
// Swift, hence `aygLowercaseUuid` everywhere an id is written.

// MARK: - Ids

extension UUID {
    // Java writes UUIDs lowercase; Foundation writes them uppercase.
    var aygLowercaseUuid: String {
        return self.uuidString.lowercased()
    }
}

// MARK: - A Gson-compatible JSON writer

private indirect enum AYGJsonValue {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([AYGJsonValue])
    case object([(String, AYGJsonValue)])
}

// `JsonWriter.HTML_SAFE_REPLACEMENT_CHARS`, which is what a plain `GsonBuilder`
// installs.
private func aygGsonQuote(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\"":
            result += "\\\""
        case "\\":
            result += "\\\\"
        case "\t":
            result += "\\t"
        case "\u{8}":
            result += "\\b"
        case "\n":
            result += "\\n"
        case "\r":
            result += "\\r"
        case "\u{c}":
            result += "\\f"
        case "<":
            result += "\\u003c"
        case ">":
            result += "\\u003e"
        case "&":
            result += "\\u0026"
        case "=":
            result += "\\u003d"
        case "'":
            result += "\\u0027"
        case "\u{2028}":
            result += "\\u2028"
        case "\u{2029}":
            result += "\\u2029"
        default:
            if scalar.value <= 0x1f {
                result += String(format: "\\u%04x", scalar.value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
    }
    result += "\""
    return result
}

// `JsonWriter` in pretty mode: two spaces of indent, `": "` between a name and
// its value, and an empty array or object closed on the same line.
private func aygGsonWrite(_ value: AYGJsonValue, into result: inout String, depth: Int) {
    switch value {
    case .null:
        result += "null"
    case let .bool(value):
        result += value ? "true" : "false"
    case let .int(value):
        result += "\(value)"
    case let .string(value):
        result += aygGsonQuote(value)
    case let .array(items):
        if items.isEmpty {
            result += "[]"
            return
        }
        result += "["
        for (index, item) in items.enumerated() {
            if index != 0 {
                result += ","
            }
            result += "\n" + String(repeating: "  ", count: depth + 1)
            aygGsonWrite(item, into: &result, depth: depth + 1)
        }
        result += "\n" + String(repeating: "  ", count: depth) + "]"
    case let .object(fields):
        if fields.isEmpty {
            result += "{}"
            return
        }
        result += "{"
        for (index, field) in fields.enumerated() {
            if index != 0 {
                result += ","
            }
            result += "\n" + String(repeating: "  ", count: depth + 1)
            result += aygGsonQuote(field.0) + ": "
            aygGsonWrite(field.1, into: &result, depth: depth + 1)
        }
        result += "\n" + String(repeating: "  ", count: depth) + "}"
    }
}

// MARK: - Export

// `AyuFilterUtils.export()`. Every filter and every exclusion, plus a
// `dialogId -> "@username"` map for the dialogs the receiving client may not
// know yet — Android fills that from `DialogObject.getPublicUsername`, and only
// for dialogs that actually have one.
func aygFiltersExport(state: AYGFiltersState) -> String {
    var exclusions: [AYGJsonValue] = []
    for exclusion in state.exclusions {
        exclusions.append(.object([
            ("dialogId", .int(exclusion.dialogId)),
            ("filterId", .string(exclusion.filterId.aygLowercaseUuid))
        ]))
    }

    var filters: [AYGJsonValue] = []
    for filter in state.filters {
        filters.append(.object([
            ("caseInsensitive", .bool(filter.caseInsensitive)),
            ("dialogId", filter.dialogId.map({ AYGJsonValue.int($0) }) ?? .null),
            ("enabled", .bool(filter.isEnabled)),
            ("id", .string(filter.id.aygLowercaseUuid)),
            ("reversed", .bool(filter.reversed)),
            ("text", .string(filter.text))
        ]))
    }

    // Android walks a HashMap here, so its order is arbitrary; first appearance
    // is the stable equivalent.
    var peers: [(String, AYGJsonValue)] = []
    var seenPeers = Set<Int64>()
    for filter in state.filters {
        guard let dialogId = filter.dialogId, !seenPeers.contains(dialogId) else {
            continue
        }
        guard let peer = state.peers[dialogId], let username = peer.addressName, !username.isEmpty else {
            continue
        }
        seenPeers.insert(dialogId)
        peers.append(("\(dialogId)", .string("@" + username)))
    }

    let backup = AYGJsonValue.object([
        ("exclusions", .array(exclusions)),
        ("filters", .array(filters)),
        ("peers", .object(peers)),
        // `export()` leaves both of these null, and `serializeNulls()` writes them.
        ("removeExclusions", .null),
        ("removeFiltersById", .null),
        ("version", .int(Int64(aygFiltersBackupVersion)))
    ])

    var result = ""
    aygGsonWrite(backup, into: &result, depth: 0)
    return result
}

// MARK: - Import

// `AyuFilterUtils.BACKUP_VERSION`.
let aygFiltersBackupVersion: Int = 2

// `AyuFilterUtils.ApplyChanges`, field for field.
struct AYGFiltersApplyChanges {
    var newFilters: [AYGRegexFilter] = []
    var removeFiltersById: [UUID] = []
    var filtersOverrides: [AYGRegexFilter] = []
    var newExclusions: [AYGFilterExclusion] = []
    var removeExclusions: [AYGFilterExclusion] = []
    var peersToBeResolved: [(Int64, String)] = []

    var isEmpty: Bool {
        return self.newFilters.isEmpty
            && self.removeFiltersById.isEmpty
            && self.filtersOverrides.isEmpty
            && self.newExclusions.isEmpty
            && self.removeExclusions.isEmpty
            && self.peersToBeResolved.isEmpty
    }
}

private func aygJsonBool(_ value: Any?) -> Bool {
    return (value as? NSNumber)?.boolValue ?? false
}

private func aygJsonInt64(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber {
        return number.int64Value
    }
    if let string = value as? String {
        return Int64(string)
    }
    return nil
}

// `AyuFilterUtils.filterEquals`: every field, id included.
private func aygFilterEquals(_ lhs: AYGRegexFilter, _ rhs: AYGRegexFilter) -> Bool {
    return lhs.id == rhs.id
        && lhs.text == rhs.text
        && lhs.caseInsensitive == rhs.caseInsensitive
        && lhs.reversed == rhs.reversed
        && lhs.dialogId == rhs.dialogId
        && lhs.isEnabled == rhs.isEnabled
}

// `AyuFilterUtils.prepareChanges`. Returns nil where Android catches
// `JsonSyntaxException` and reports "Failed to import filters.".
//
// One Gson behaviour worth naming: `RegexFilter.id` is initialised to
// `UUID.randomUUID()` in the field declaration, so a filter that arrives
// without an `id` gets a fresh one rather than being rejected.
func aygFiltersPrepareChanges(json: String, state: AYGFiltersState) -> AYGFiltersApplyChanges? {
    guard let data = json.data(using: .utf8) else {
        return nil
    }
    guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []), let backup = parsed as? [String: Any] else {
        return nil
    }
    let version = aygJsonInt64(backup["version"]) ?? 0
    if version > Int64(aygFiltersBackupVersion) {
        return nil
    }

    var changes = AYGFiltersApplyChanges()

    // A LinkedHashMap keyed by id on Android: duplicates collapse, first
    // appearance wins the position.
    var newFilterIds: [UUID: Int] = [:]

    if let rawFilters = backup["filters"] as? [Any] {
        for rawFilter in rawFilters {
            guard let rawFilter = rawFilter as? [String: Any] else {
                return nil
            }
            let id: UUID
            if let rawId = rawFilter["id"] as? String {
                guard let parsedId = UUID(uuidString: rawId) else {
                    return nil
                }
                id = parsedId
            } else {
                id = UUID()
            }
            let filter = AYGRegexFilter(
                id: id,
                dialogId: aygJsonInt64(rawFilter["dialogId"]),
                text: rawFilter["text"] as? String ?? "",
                isEnabled: aygJsonBool(rawFilter["enabled"]),
                caseInsensitive: aygJsonBool(rawFilter["caseInsensitive"]),
                reversed: aygJsonBool(rawFilter["reversed"])
            )
            if let existing = state.filters.first(where: { $0.id == filter.id }) {
                if !aygFilterEquals(existing, filter) {
                    changes.filtersOverrides.append(filter)
                }
            } else if let index = newFilterIds[filter.id] {
                changes.newFilters[index] = filter
            } else {
                newFilterIds[filter.id] = changes.newFilters.count
                changes.newFilters.append(filter)
            }
        }
    }

    if let rawExclusions = backup["exclusions"] as? [Any] {
        for rawExclusion in rawExclusions {
            guard let rawExclusion = rawExclusion as? [String: Any] else {
                return nil
            }
            guard let rawFilterId = rawExclusion["filterId"] as? String, let filterId = UUID(uuidString: rawFilterId) else {
                return nil
            }
            let dialogId = aygJsonInt64(rawExclusion["dialogId"]) ?? 0
            let exclusion = AYGFilterExclusion(dialogId: dialogId, filterId: filterId)
            if !state.exclusions.contains(where: { $0.dialogId == dialogId && $0.filterId == filterId }) {
                changes.newExclusions.append(exclusion)
            }
        }
    }

    // Both removal lists are filtered down to what this client actually has.
    if let rawRemoved = backup["removeFiltersById"] as? [Any] {
        for rawId in rawRemoved {
            guard let rawId = rawId as? String, let id = UUID(uuidString: rawId) else {
                return nil
            }
            if state.filters.contains(where: { $0.id == id }) {
                changes.removeFiltersById.append(id)
            }
        }
    }

    if let rawRemoved = backup["removeExclusions"] as? [Any] {
        for rawExclusion in rawRemoved {
            guard let rawExclusion = rawExclusion as? [String: Any] else {
                return nil
            }
            guard let rawFilterId = rawExclusion["filterId"] as? String, let filterId = UUID(uuidString: rawFilterId) else {
                return nil
            }
            let dialogId = aygJsonInt64(rawExclusion["dialogId"]) ?? 0
            if state.exclusions.contains(where: { $0.dialogId == dialogId && $0.filterId == filterId }) {
                changes.removeExclusions.append(AYGFilterExclusion(dialogId: dialogId, filterId: filterId))
            }
        }
    }

    if let rawPeers = backup["peers"] as? [String: Any] {
        for key in rawPeers.keys.sorted() {
            guard let dialogId = Int64(key) else {
                return nil
            }
            guard let username = rawPeers[key] as? String else {
                return nil
            }
            if state.peers[dialogId] == nil {
                changes.peersToBeResolved.append((dialogId, username))
            }
        }
    }

    return changes
}

// `AyuFilterUtils.applyChanges`, in the same order, against the in-memory model
// instead of the Room database. `peersToBeResolved` is where Android calls
// `AyuRequestUtils.resolveAllChats`; this screen makes no requests, so those
// dialogs stay unresolved and their rows show the raw id, exactly as Android's
// do until the resolve comes back.
func aygFiltersApplyChanges(_ changes: AYGFiltersApplyChanges, to state: AYGFiltersState) -> AYGFiltersState {
    var state = state

    for filter in changes.newFilters {
        state.filters.append(filter)
    }
    for id in changes.removeFiltersById {
        state.filters.removeAll(where: { $0.id == id })
    }
    for filter in changes.filtersOverrides {
        if let index = state.filters.firstIndex(where: { $0.id == filter.id }) {
            state.filters[index] = filter
        }
    }
    for exclusion in changes.newExclusions {
        state.exclusions.append(exclusion)
    }
    for exclusion in changes.removeExclusions {
        state.exclusions.removeAll(where: { $0.dialogId == exclusion.dialogId && $0.filterId == exclusion.filterId })
    }

    return state
}

// The body of `FiltersImportBottomSheet`: one line per non-empty bucket, in the
// order Android appends them. The `**…**` is Android's `replaceTags`, which
// `ActionSheetTextItem` parses as markdown here.
func aygFiltersImportSummary(_ changes: AYGFiltersApplyChanges) -> String {
    var lines: [String] = []
    let buckets: [(Int, String)] = [
        (changes.newFilters.count, "FiltersSheetNewFilters"),
        (changes.removeFiltersById.count, "FiltersSheetRemovedFilters"),
        (changes.filtersOverrides.count, "FiltersSheetUpdatedFilters"),
        (changes.newExclusions.count, "FiltersSheetNewExclusions"),
        (changes.removeExclusions.count, "FiltersSheetRemovedExclusions"),
        (changes.peersToBeResolved.count, "FiltersSheetDialogsToResolve")
    ]
    for (count, key) in buckets where count != 0 {
        lines.append(aygPluralString(key, count))
    }
    return lines.joined(separator: "\n")
}

// MARK: - Transport

// AYG: the two network calls the Filters screen makes. Both are ports of
// AyuGram for Android's OkHttp usage, and both are deliberately plain
// `URLSession` rather than Telegram's own stack: neither talks to Telegram, and
// routing a dpaste.com request through MTProto would be both wrong and
// impossible.
//
// Nothing here invents a service. `dpaste.com` is the paste host AyuGram itself
// posts to, hit with the same endpoint, the same three form fields and the same
// `Location`-header handling.

/// `AyuFilterUtils.importFromLink`: GET the URL and hand the body back.
///
/// Android follows redirects (`followRedirects(true)`), which is what makes a
/// dpaste short link work, and treats a non-2xx or an empty body as a failure —
/// `nil` here, which the caller turns into `FiltersToastFailImport`. A transport
/// error is `FiltersToastFailFetch`, so the two are distinguished by
/// `didConnect`.
func aygFiltersFetch(url: String) -> Signal<(body: String?, didConnect: Bool), NoError> {
    return Signal { subscriber in
        guard let requestUrl = URL(string: url) else {
            subscriber.putNext((body: nil, didConnect: false))
            subscriber.putCompletion()
            return EmptyDisposable
        }
        var request = URLRequest(url: requestUrl)
        request.httpMethod = "GET"
        request.timeoutInterval = 30.0

        let task = URLSession.shared.dataTask(with: request, completionHandler: { data, response, error in
            if error != nil {
                subscriber.putNext((body: nil, didConnect: false))
                subscriber.putCompletion()
                return
            }
            var body: String?
            if let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode), let data {
                body = String(data: data, encoding: .utf8)
            }
            subscriber.putNext((body: body, didConnect: true))
            subscriber.putCompletion()
        })
        task.resume()
        return ActionDisposable {
            task.cancel()
        }
    }
}

/// `FiltersPreferencesActivity.lambda$exportFilters$4(_, 1)` plus its
/// `AnonymousClass3` callback: POST the export to dpaste.com as multipart form
/// data — `content`, `syntax=json`, `title="AyuGram Filters"` — and read the
/// created paste's URL out of the `Location` response header.
///
/// Android returns `Location + ".txt"`, which is dpaste's raw-text view and the
/// only form `importFromLink` can parse back. `nil` means the response carried
/// no `Location`, which is `FiltersToastFailPublish`; `didConnect == false` is
/// the transport error, which Android reports as `FiltersToastFailFetch` — a
/// mislabel in the original, reproduced because these two strings are the ones
/// the APK actually raises here.
func aygFiltersPublish(content: String) -> Signal<(url: String?, didConnect: Bool), NoError> {
    return Signal { subscriber in
        guard let requestUrl = URL(string: "https://dpaste.com/api/v2/") else {
            subscriber.putNext((url: nil, didConnect: false))
            subscriber.putCompletion()
            return EmptyDisposable
        }
        let boundary = "AYGFilters-\(UUID().uuidString)"
        var body = ""
        for (name, value) in [("content", content), ("syntax", "json"), ("title", "AyuGram Filters")] {
            body += "--\(boundary)\r\n"
            body += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
            body += value
            body += "\r\n"
        }
        body += "--\(boundary)--\r\n"

        var request = URLRequest(url: requestUrl)
        request.httpMethod = "POST"
        request.timeoutInterval = 30.0
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        let task = URLSession.shared.dataTask(with: request, completionHandler: { data, response, error in
            if error != nil {
                subscriber.putNext((url: nil, didConnect: false))
                subscriber.putCompletion()
                return
            }
            var location: String?
            if let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) {
                if let value = httpResponse.value(forHTTPHeaderField: "Location"), !value.isEmpty {
                    location = value + ".txt"
                } else if let data, let text = String(data: data, encoding: .utf8) {
                    // dpaste answers a plain `POST` with the paste URL in the
                    // body as well; Android only ever reads the header, so this
                    // is a fallback and not a second code path.
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("https://") {
                        location = trimmed + ".txt"
                    }
                }
            }
            subscriber.putNext((url: location, didConnect: true))
            subscriber.putCompletion()
        })
        task.resume()
        return ActionDisposable {
            task.cancel()
        }
    }
}
