import Foundation
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `ModelAssignmentSelection.parse(_:knownAliasNames:)`/`.rawValue`
/// (`docs/design/44-llm-model-config.md` §9's 機能別割り当て `Picker`'s "値 ↔ config 文字列の変換").
/// `ModelAssignmentPicker` (the SwiftUI view) is not tested per this module's plan.
@Suite("ModelAssignmentSelection")
struct ModelAssignmentSelectionTests {
    private let aliasNames = ["auto", "premium", "cheap"]

    // MARK: - parse

    @Test("an exact alias-name match parses to .alias")
    func exactAliasNameParsesToAlias() {
        #expect(
            ModelAssignmentSelection.parse("premium", knownAliasNames: aliasNames) == .alias("premium")
        )
    }

    @Test("a provider/model pair parses to .direct")
    func providerModelPairParsesToDirect() {
        #expect(
            ModelAssignmentSelection.parse("azure/gpt-5.4-mini", knownAliasNames: aliasNames)
                == .direct("azure/gpt-5.4-mini")
        )
    }

    @Test("a bare model name (not a known alias) parses to .direct")
    func bareModelNameParsesToDirect() {
        #expect(
            ModelAssignmentSelection.parse("claude-haiku-4-5-20251001", knownAliasNames: aliasNames)
                == .direct("claude-haiku-4-5-20251001")
        )
    }

    @Test("an empty value always parses to .unset -- every field's empty value means デフォルト now (§9)")
    func emptyValueAlwaysParsesToUnset() {
        #expect(ModelAssignmentSelection.parse("", knownAliasNames: aliasNames) == .unset)
    }

    @Test("a stale alias name no longer present in knownAliasNames parses to .direct")
    func staleAliasNameParsesToDirect() {
        #expect(
            ModelAssignmentSelection.parse("deleted-alias", knownAliasNames: aliasNames) == .direct("deleted-alias")
        )
    }

    // MARK: - rawValue

    @Test("rawValue round-trips every case back to its exact persisted string")
    func rawValueRoundTrips() {
        #expect(ModelAssignmentSelection.unset.rawValue == "")
        #expect(ModelAssignmentSelection.alias("auto").rawValue == "auto")
        #expect(ModelAssignmentSelection.direct("azure/gpt-5.4-mini").rawValue == "azure/gpt-5.4-mini")
    }

    @Test("parse(_:knownAliasNames:).rawValue is idempotent for every case")
    func parseThenRawValueIsIdempotent() {
        for raw in ["auto", "azure/gpt-5.4-mini", "claude-haiku-4-5-20251001", ""] {
            let selection = ModelAssignmentSelection.parse(raw, knownAliasNames: aliasNames)
            #expect(selection.rawValue == raw)
        }
    }
}
