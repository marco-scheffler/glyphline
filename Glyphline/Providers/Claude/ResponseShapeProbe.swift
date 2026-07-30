import Foundation

// TEMPORARY DIAGNOSTIC — added 2026-07-30.
//
// A second Claude login reports `unexpectedResponseShape` during sign-in even
// though the user is demonstrably signed in, which means
// `GET /api/organizations` answered 2xx with a non-HTML body that did not decode
// as `[ClaudeOrganization]`. Reading the code has not explained the difference to
// the first account, so this probe reports the *structure* of that body in the
// sign-in window's status line.
//
// A second, related silence: for one subscription `/usage` decodes cleanly and
// yields *no* rate window at all, with no failure message, so the panel says
// "No quota reported yet." and nothing distinguishes an idle subscription from a
// shape the tolerant decoder skipped. The probe therefore also runs on the
// polling path, and for that case it descends one level into `five_hour` and
// `seven_day` — still key names and value types only.
//
// A third question, the one the probe now also measures: per-account cost. The
// usage body carries dollar-shaped fields the app does not decode — `spend`,
// `limits`, `extra_usage`, and the `*_dollars` keys inside the windows. Whether
// they carry numbers on an *active* subscription decides whether real
// provider-reported cost is available at all, so the summary descends into
// `spend` (two levels, since a figure most likely lives one level down),
// reports `limits`' element count and its first element's shape, and reports
// `extra_usage`'s keys. It rides along on every successful poll, not only the
// empty-window case, because only an active account produces windows.
//
// Remove this file, its tests and its two call sites — in `ClaudeSignInWindow`
// and in `ClaudeWebQuotaSource.result(from:body:observedAt:)` — once the
// difference is understood.
//
// **Shape only, never content.** The probe may emit the byte length, the first
// non-whitespace character, whether the body parses as JSON, the top-level JSON
// type, an array's element count, JSON *key names* and the JSON *type* of each
// value (`null`, `bool`, `number`, `string`, `object`, `array`) — key names are
// API field names and are already documented in
// `docs/superpowers/specs/2026-07-29-claude-org-id-discovery.md`. It must never
// emit a JSON value, a substring of the body, a URL, an organisation id or an
// account name. A fact that cannot be stated without risking a value is omitted.
enum ResponseShapeProbe {
    /// A one-line structural summary of `body`, safe to render.
    static func describe(_ body: String) -> String {
        let byteCount = body.utf8.count

        guard let firstNonWhitespace = body.first(where: { !$0.isWhitespace }) else {
            return byteCount == 0 ? "0 bytes, empty" : "\(byteCount) bytes, whitespace only"
        }

        let prefix = "\(byteCount) bytes, starts '\(firstNonWhitespace)'"

        guard let parsed = try? JSONSerialization.jsonObject(
            with: Data(body.utf8),
            options: [.fragmentsAllowed]
        ) else {
            return "\(prefix), does not parse as JSON"
        }

        if let array = parsed as? [Any] {
            var summary = "\(prefix), JSON array, \(array.count) elements"
            if let first = array.first {
                if let object = first as? [String: Any] {
                    summary += ", first element keys: \(keyList(of: object))"
                } else {
                    summary += ", first element is not an object"
                }
            }
            return summary
        }

        if let object = parsed as? [String: Any] {
            var summary = "\(prefix), JSON object, keys: \(keyList(of: object))"
            for key in nestedKeys {
                summary += "; \(nestedDescription(of: object, key: key))"
            }
            summary += "; \(spendDescription(of: object))"
            summary += "; \(limitsDescription(of: object))"
            return summary
        }

        return "\(prefix), JSON but neither array nor object"
    }

    /// The only keys the probe descends into. The question this diagnostic exists
    /// to answer is what is *inside* the two usage windows; every other key stays
    /// at one level, so nothing else can be described by accident.
    private static let nestedKeys = ["five_hour", "seven_day", "extra_usage"]

    /// The key most likely to carry a provider-reported cost. It is the one place
    /// the probe descends a *second* level — still key names and value types only.
    private static let spendKey = "spend"

    /// The array of limit descriptors: element count, plus the first element's
    /// key names and value types when the elements are objects.
    private static let limitsKey = "limits"

    /// `spend`'s own keys and types, plus one further level for each of its
    /// object-valued keys.
    private static func spendDescription(of object: [String: Any]) -> String {
        guard let value = object[spendKey] else {
            return "\(spendKey) absent"
        }
        guard let spend = value as? [String: Any] else {
            if value is NSNull { return "\(spendKey) is null" }
            return "\(spendKey) is not an object"
        }

        var description = "\(spendKey){\(keyList(of: spend))}"
        for key in spend.keys.sorted() {
            guard let nested = spend[key] as? [String: Any] else { continue }
            description += "; \(spendKey).\(key){\(keyList(of: nested))}"
        }
        return description
    }

    /// `limits`' element count, and the first element's shape when it is an object.
    private static func limitsDescription(of object: [String: Any]) -> String {
        guard let value = object[limitsKey] else {
            return "\(limitsKey) absent"
        }
        guard let limits = value as? [Any] else {
            if value is NSNull { return "\(limitsKey) is null" }
            return "\(limitsKey) is not an array"
        }

        var description = "\(limitsKey): \(limits.count) elements"
        if let first = limits.first {
            if let element = first as? [String: Any] {
                description += ", first element keys: \(keyList(of: element))"
            } else {
                description += ", first element is not an object"
            }
        }
        return description
    }

    /// One nested key's own key names and value types — or, plainly, that there
    /// is nothing there to describe.
    private static func nestedDescription(of object: [String: Any], key: String) -> String {
        guard let value = object[key] else {
            return "\(key) absent"
        }
        guard let nested = value as? [String: Any] else {
            if value is NSNull { return "\(key) is null" }
            return "\(key) is not an object"
        }
        return "\(key){\(keyList(of: nested))}"
    }

    /// Key names and the *type* of each value — never the values themselves.
    private static func keyList(of object: [String: Any]) -> String {
        guard !object.isEmpty else { return "none" }
        return object.keys.sorted()
            .map { "\($0): \(typeName(of: object[$0]))" }
            .joined(separator: ", ")
    }

    /// The JSON type of a value, which never reveals the value.
    private static func typeName(of value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
        }
        if value is String { return "string" }
        if value is [Any] { return "array" }
        if value is [String: Any] { return "object" }
        return "unknown"
    }
}
