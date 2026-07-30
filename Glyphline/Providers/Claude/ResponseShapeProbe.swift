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
// Remove this file, its tests and its call site in `ClaudeSignInWindow` once the
// difference is understood.
//
// **Shape only, never content.** The probe may emit the byte length, the first
// non-whitespace character, whether the body parses as JSON, the top-level JSON
// type, an array's element count and JSON *key names* — key names are API field
// names and are already documented in
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
            return "\(prefix), JSON object, keys: \(keyList(of: object))"
        }

        return "\(prefix), JSON but neither array nor object"
    }

    /// Key names only — never the values they address.
    private static func keyList(of object: [String: Any]) -> String {
        object.keys.isEmpty ? "none" : object.keys.sorted().joined(separator: ", ")
    }
}
