import Foundation
import Testing

@testable import Kikimi

/// Layer 1 coverage for `WatcherStateMerge` (`docs/design/05-watcher-runner.md` §7):
/// cumulative/snapshot full replacement, and append_only's array-append + non-array-null-skip merge.
@Suite("WatcherStateMerge")
struct WatcherStateMergeTests {
    private func obj(_ members: [(String, JSONValue)]) -> JSONValue {
        .object(members.map { JSONValue.Member(key: $0.0, value: $0.1) })
    }

    // MARK: - cumulative / snapshot

    @Test("cumulative replaces the entire state with the LLM's output")
    func cumulativeReplacesEntireState() {
        let current = obj([("overview", .string("old"))])
        let llmOutput = obj([("overview", .string("new"))])
        let merged = WatcherStateMerge.apply(llmOutput: llmOutput, to: current, stateMode: .cumulative)
        #expect(merged == llmOutput)
    }

    @Test("cumulative with no prior state (first run) just returns the LLM's output")
    func cumulativeWithNoPriorState() {
        let llmOutput = obj([("overview", .string("first"))])
        let merged = WatcherStateMerge.apply(llmOutput: llmOutput, to: nil, stateMode: .cumulative)
        #expect(merged == llmOutput)
    }

    @Test("snapshot replaces the entire state with the LLM's output, same as cumulative")
    func snapshotReplacesEntireState() {
        let current = obj([("overview", .string("old"))])
        let llmOutput = obj([("overview", .string("rebuilt"))])
        let merged = WatcherStateMerge.apply(llmOutput: llmOutput, to: current, stateMode: .snapshot)
        #expect(merged == llmOutput)
    }

    // MARK: - append_only

    @Test("append_only appends the LLM's array elements to the end of the existing array")
    func appendOnlyAppendsArrayElements() {
        let current = obj([("items", .array([.string("a"), .string("b")]))])
        let llmOutput = obj([("items", .array([.string("c")]))])
        let merged = WatcherStateMerge.apply(llmOutput: llmOutput, to: current, stateMode: .appendOnly)
        #expect(merged == obj([("items", .array([.string("a"), .string("b"), .string("c")]))]))
    }

    @Test("append_only with no prior array field just uses the LLM's array as-is")
    func appendOnlyWithNoPriorArray() {
        let llmOutput = obj([("items", .array([.string("a")]))])
        let merged = WatcherStateMerge.apply(llmOutput: llmOutput, to: nil, stateMode: .appendOnly)
        #expect(merged == llmOutput)
    }

    @Test("append_only replaces a non-array field only when the LLM returns a non-null value")
    func appendOnlyReplacesNonArrayFieldOnlyWhenNonNull() {
        let current = obj([("summary", .string("old summary"))])
        let llmOutputWithChange = obj([("summary", .string("new summary"))])
        let mergedWithChange = WatcherStateMerge.apply(llmOutput: llmOutputWithChange, to: current, stateMode: .appendOnly)
        #expect(mergedWithChange == obj([("summary", .string("new summary"))]))

        let llmOutputNoChange = obj([("summary", .null)])
        let mergedNoChange = WatcherStateMerge.apply(llmOutput: llmOutputNoChange, to: current, stateMode: .appendOnly)
        #expect(mergedNoChange == obj([("summary", .string("old summary"))]))
    }

    @Test("append_only handles a mix of array-append and non-array-replace fields in one call")
    func appendOnlyHandlesMixedFields() {
        let current = obj([
            ("items", .array([.string("a")])),
            ("summary", .string("old"))
        ])
        let llmOutput = obj([
            ("items", .array([.string("b")])),
            ("summary", .null)
        ])
        let merged = WatcherStateMerge.apply(llmOutput: llmOutput, to: current, stateMode: .appendOnly)
        #expect(merged == obj([
            ("items", .array([.string("a"), .string("b")])),
            ("summary", .string("old"))
        ]))
    }
}
