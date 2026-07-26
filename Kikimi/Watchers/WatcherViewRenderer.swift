import Foundation
import Mustache
import OSLog

// MARK: - WatcherViewRenderer

/// Renders a Watcher's `state` (a schema-validated `JSONValue`) to Markdown via its `view` Mustache
/// template, with derived enum flags injected (`docs/design/05-watcher-runner.md` §8). Uses the same
/// GRMustache.swift library as `SummaryRenderer` (product name `Mustache`).
enum WatcherViewRenderer {
    private static let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "WatcherViewRenderer")

    /// Renders `state` with `template`. Returns `nil` if the template fails to compile/render (§8
    /// step 3; §12's "view の Mustache コンパイル/レンダ失敗 -> `.failed`。state は更新済みのまま") -- the
    /// caller keeps whatever was previously displayed and shows an error badge instead.
    static func render(state: JSONValue, schema: WatcherSchema, template: String) -> String? {
        let context = objectContext(for: state, fields: schema.fields)
        do {
            let mustacheTemplate = try Template(string: template)
            let rendered = try mustacheTemplate.render(context)
            return linkifySegmentIds(in: rendered)
        } catch {
            logger.warning("Watcher view render failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - JSONValue -> Mustache box, with derived flags (§8 step 1/2)

    /// Converts an object-shaped `JSONValue` into the `[String: Any]` Mustache expects, recursing
    /// into nested object/array fields per `fields`' declared types. For every enum field, also
    /// injects `is_<value>: Bool` for each of the enum's declared values (§8 step 2) -- `true` only
    /// for the value matching the field's current string, all `false` when the field is `null`. A
    /// derived flag name colliding with an already-declared field name is skipped with a `.warning`
    /// log (the declared field wins, per §8 step 2's "宣言済みフィールド名と衝突する場合は注入しない（宣言が
    /// 勝つ）＋ warning ログ").
    private static func objectContext(for value: JSONValue, fields: [WatcherSchema.Field]) -> [String: Any] {
        guard case .object(let members) = value else { return [:] }
        let byKey = Dictionary(members.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        let declaredNames = Set(fields.map(\.name))

        var context: [String: Any] = [:]
        for field in fields {
            let fieldValue = byKey[field.name] ?? .null
            context[field.name] = box(for: fieldValue, type: field.type)

            guard case .enumeration(let allowedValues) = field.type else { continue }
            let currentStringValue: String? = { if case .string(let stringValue) = fieldValue { return stringValue } else { return nil } }()
            for allowedValue in allowedValues {
                let flagName = "is_\(allowedValue)"
                guard !declaredNames.contains(flagName) else {
                    logger.warning(
                        "Skipping derived flag \"\(flagName, privacy: .public)\" for field \"\(field.name, privacy: .public)\": collides with a declared field name."
                    )
                    continue
                }
                context[flagName] = currentStringValue == allowedValue
            }
        }
        return context
    }

    /// Converts one field's value into a Mustache-boxable `Any`, recursing through `array`/`object`
    /// field types. `NSNull` for `.null` (§8 step 1's explicit box shape list: "`[String: Any]` /
    /// `[Any]` / `String` / `Int` / `Double` / `Bool` / `NSNull`"), which GRMustache.swift treats as
    /// falsy -- matching `SummaryRenderer`'s own nil-is-falsy convention.
    private static func box(for value: JSONValue, type: WatcherSchema.FieldType) -> Any {
        switch (value, type) {
        case (.null, _):
            return NSNull()
        case (.string(let stringValue), _):
            return stringValue
        case (.int(let intValue), _):
            return intValue
        case (.double(let doubleValue), _):
            return doubleValue
        case (.bool(let boolValue), _):
            return boolValue
        case (.array(let items), .array(let elementType)):
            return items.map { box(for: $0, type: elementType) }
        case (.object, .object(let nestedFields)):
            return objectContext(for: value, fields: nestedFields)
        default:
            // A shape mismatch between `value` and `type` should not occur for schema-validated
            // state, but rendering must never crash on it -- fall back to falsy `NSNull()`.
            return NSNull()
        }
    }

    // MARK: - seg ID linkification (§8.1)

    /// Matches either a backticked seg id (capture group 1: the id without backticks) or a bare seg
    /// id (capture group 2) -- a single combined pattern so both forms are found in one pass over the
    /// *original* rendered Markdown, never by re-scanning text this function itself just produced
    /// (see `linkifySegmentIds(in:)`'s doc comment for why that matters).
    private static let combinedSegIdPattern = try! NSRegularExpression(pattern: "`(seg_[0-9]{5})`|(seg_[0-9]{5})") // swiftlint:disable:this force_try

    /// Rewrites every seg id occurrence in `markdown` into a `[seg_XXXXX](kikimi-seg:seg_XXXXX)` link
    /// (§8.1), so the Watchers tab's `OpenURLAction` can jump to that segment in the Transcript tab.
    ///
    /// Finds every match against the *original* `markdown` text in a single pass
    /// (`combinedSegIdPattern`), then applies the replacements to a mutable copy from the last match
    /// to the first. Processing back-to-front is what makes this safe without re-scanning: every
    /// match's `Range` is recomputed against the current state of `result` right before it's used,
    /// but since matches are visited in decreasing position order, nothing *before* the match being
    /// processed has been touched yet, so that recomputed `Range` is still valid. This also sidesteps
    /// the alternative bug a naive two-sequential-passes implementation would have: re-running the
    /// bare-id pass over the backtick pass's own output would match the id text still visible inside
    /// the link it just created (e.g. `[seg_00042]` in `[seg_00042](kikimi-seg:seg_00042)`) and wrap
    /// it again.
    ///
    /// Bare matches immediately preceded by `](` or `(kikimi-seg:` in the *original* text are left
    /// alone (§8.1: "既にリンク内にある場合を壊さないよう... スキップする") -- these are ids the view template's
    /// author already wrote inside a hand-authored Markdown link.
    private static func linkifySegmentIds(in markdown: String) -> String {
        let nsrange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        let matches = combinedSegIdPattern.matches(in: markdown, range: nsrange)
        guard !matches.isEmpty else { return markdown }

        var result = markdown
        for match in matches.reversed() {
            if match.range(at: 1).location != NSNotFound,
               let idRange = Range(match.range(at: 1), in: result),
               let fullRange = Range(match.range, in: result) {
                let id = String(result[idRange])
                result.replaceSubrange(fullRange, with: "[\(id)](kikimi-seg:\(id))")
                continue
            }
            guard match.range(at: 2).location != NSNotFound, let bareRange = Range(match.range(at: 2), in: result) else { continue }
            let precedingText = result[result.startIndex..<bareRange.lowerBound]
            guard !precedingText.hasSuffix("]("), !precedingText.hasSuffix("(kikimi-seg:") else { continue }
            let id = String(result[bareRange])
            result.replaceSubrange(bareRange, with: "[\(id)](kikimi-seg:\(id))")
        }
        return result
    }
}
