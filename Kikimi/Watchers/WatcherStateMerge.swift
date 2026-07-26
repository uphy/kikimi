import Foundation

// MARK: - WatcherStateMerge

/// Applies one LLM output onto a Watcher's current state per `state_mode`
/// (`docs/design/05-watcher-runner.md` §7). Pure: no I/O, no schema knowledge beyond what's already
/// implied by the `JSONValue` shapes it's handed.
enum WatcherStateMerge {
    /// Merges `llmOutput` (already schema-validated JSON the LLM returned) into `currentState` per
    /// `stateMode` (§7's table). `currentState` is `nil` for a Watcher's very first run (or after an
    /// `initial_state`-reset).
    ///
    /// - `cumulative`/`snapshot`: full replacement -- the LLM is expected to return the complete
    ///   updated state either way (the only difference between the two modes is what gets injected
    ///   into `{{state}}` beforehand, `WatcherPromptBuilder.stateText(for:stateMode:)`'s job).
    /// - `append_only`: `mergeAppendOnly(llmOutput:into:)` below.
    ///
    /// Does **not** re-validate the merged result against the schema -- `WatcherRunner` (§7: "マージ
    /// 結果も schema.validate に通し、不合格なら反映せずエラー扱い") owns that decision, since only it knows
    /// whether to keep the previous state on a post-merge validation failure.
    static func apply(llmOutput: JSONValue, to currentState: JSONValue?, stateMode: WatcherStateMode) -> JSONValue {
        switch stateMode {
        case .cumulative, .snapshot:
            return llmOutput
        case .appendOnly:
            return mergeAppendOnly(llmOutput: llmOutput, into: currentState)
        }
    }

    /// §7's `append_only` row: "トップレベルの配列フィールドは既存配列の末尾に LLM の返した要素を追加。非配列
    /// フィールドは LLM が非 null を返した場合のみ置換". Only operates one level deep (top-level fields) --
    /// matching the design's scope; nested arrays inside an object field are not independently
    /// append-merged.
    private static func mergeAppendOnly(llmOutput: JSONValue, into currentState: JSONValue?) -> JSONValue {
        guard case .object(let newMembers) = llmOutput else {
            // Malformed shape (a non-object LLM output somehow got here). Returned as-is; the
            // caller's post-merge `schema.validate` re-check is expected to reject this.
            return llmOutput
        }
        guard case .object(let existingMembers)? = currentState else {
            // No prior state to append to (first run) -- the LLM's own output is the result.
            return llmOutput
        }
        let existingByKey = Dictionary(existingMembers.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })

        var mergedMembers: [JSONValue.Member] = []
        mergedMembers.reserveCapacity(newMembers.count)
        for member in newMembers {
            let merged = mergedFieldValue(new: member.value, existing: existingByKey[member.key])
            mergedMembers.append(JSONValue.Member(key: member.key, value: merged))
        }
        return .object(mergedMembers)
    }

    private static func mergedFieldValue(new: JSONValue, existing: JSONValue?) -> JSONValue {
        switch new {
        case .array(let newItems):
            guard case .array(let existingItems)? = existing else {
                return .array(newItems)
            }
            return .array(existingItems + newItems)
        case .null:
            // "LLM が非 null を返した場合のみ置換" -- null means "no change", so keep whatever was there.
            return existing ?? .null
        default:
            return new
        }
    }
}
