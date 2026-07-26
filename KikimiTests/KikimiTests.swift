import Testing

@Suite("Kikimi bootstrap")
struct KikimiTests {
    @Test("placeholder")
    func placeholder() {
        #expect(1 + 1 == 2)
    }
}
