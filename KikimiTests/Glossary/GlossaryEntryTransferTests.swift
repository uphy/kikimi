import Foundation
import Testing

@testable import Kikimi

/// `docs/design/28-glossary.md` §4.3's drag payload for moving a 用語集 entry between the drag handle
/// and a drop target (sidebar row or reorder separator). Only the `Codable` round-trip is tested here --
/// the `Transferable`/`NSItemProvider` machinery itself requires an actual drag session to exercise, and
/// is out of reach of a unit test.
@Suite("GlossaryEntryTransfer")
struct GlossaryEntryTransferTests {
    @Test("encodes and decodes back to an equal value")
    func codableRoundTrip() throws {
        let original = GlossaryEntryTransfer(index: 3, term: "nekosuke")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GlossaryEntryTransfer.self, from: data)

        #expect(decoded.index == original.index)
        #expect(decoded.term == original.term)
    }

    @Test("round-trips a term containing non-ASCII characters")
    func codableRoundTripWithNonASCIITerm() throws {
        let original = GlossaryEntryTransfer(index: 0, term: "ステージング環境")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GlossaryEntryTransfer.self, from: data)

        #expect(decoded.index == original.index)
        #expect(decoded.term == original.term)
    }
}
