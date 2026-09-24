import Foundation
import Testing
@testable import StudioCore

struct PromptCompilerTests {
    @Test func mapsAllSevenModesAndPreservesSource() throws {
        let expected = ["podcast", "advertisement", "drama", "drama", "drama", "narration", "auto"]
        for (mode, mapped) in zip(CreationMode.allCases, expected) {
            let result = try PromptCompiler.compile(mode: mode, prompt: "  台词  保留\n标点！  ", bindings: [])
            #expect(result.providerMode == mapped)
            #expect(result.model == "qwen-audio-3.1-tts-next")
            #expect(result.text.hasSuffix("\n内容与台词：\n台词  保留\n标点！"))
            #expect(result.scalarCount == result.text.unicodeScalars.count)
        }
    }

    @Test func limitsFinalUnicodeScalarsIncludingWrapper() throws {
        let overhead = try PromptCompiler.compile(mode: .auto, prompt: "字", bindings: []).scalarCount - 1
        let text = String(repeating: "🎵", count: 3000 - overhead)
        #expect(try PromptCompiler.compile(mode: .auto, prompt: text, bindings: []).scalarCount == 3000)
        #expect(throws: PromptValidationError.tooLong) {
            try PromptCompiler.compile(mode: .auto, prompt: text + "\u{301}", bindings: [])
        }
        #expect(throws: PromptValidationError.empty) {
            try PromptCompiler.compile(mode: .auto, prompt: " \n", bindings: [])
        }
    }

    @Test func stableSlotsSurviveOrderingAndRejectRemovedOrDuplicateBindings() throws {
        let first = ReferenceBinding(referenceID: "voice-a", alias: "甲", slot: 1)
        let second = ReferenceBinding(referenceID: "voice-b", alias: "乙", slot: 2)
        let a = try PromptCompiler.compile(mode: .drama, prompt: "@voice2 你好", bindings: [first, second])
        let b = try PromptCompiler.compile(mode: .drama, prompt: "@voice2 你好", bindings: [second, first])
        #expect(a == b)
        #expect(a.bindings[1].referenceID == "voice-b")
        #expect(throws: PromptValidationError.self) { try PromptCompiler.compile(mode: .drama, prompt: "@voice2", bindings: [first]) }
        #expect(throws: PromptValidationError.self) { try PromptCompiler.compile(mode: .drama, prompt: "@voice2", bindings: [second]) }
        #expect(throws: PromptValidationError.self) { try PromptCompiler.compile(mode: .drama, prompt: "@voice1", bindings: [first, first]) }
        #expect(throws: PromptValidationError.self) { try PromptCompiler.compile(mode: .drama, prompt: "@voice4", bindings: [first]) }
        #expect(throws: PromptValidationError.self) { try PromptCompiler.compile(mode: .drama, prompt: "@voice01", bindings: [first]) }
        #expect(try JSONDecoder().decode(ReferenceBinding.self, from: JSONEncoder().encode(second)) == second)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ReferenceBinding.self, from: Data(#"{"referenceID":"old","alias":"old"}"#.utf8)) }
    }
}
