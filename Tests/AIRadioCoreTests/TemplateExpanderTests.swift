import Testing
@testable import AIRadioCore

struct TemplateExpanderTests {
    @Test func replacesKnownPlaceholders() {
        let out = TemplateExpander.expand("{a} と {b}", values: ["a": "X", "b": "Y"])
        #expect(out == "X と Y")
    }

    @Test func leavesUnknownPlaceholdersIntact() {
        let out = TemplateExpander.expand("{a}{c}", values: ["a": "X"])
        #expect(out == "X{c}")
    }

    @Test func emptyValuesReturnsTemplate() {
        let out = TemplateExpander.expand("そのまま", values: [:])
        #expect(out == "そのまま")
    }
}
