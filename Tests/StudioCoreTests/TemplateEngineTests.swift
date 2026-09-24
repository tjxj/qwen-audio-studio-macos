import Foundation
import Testing
@testable import StudioCore

struct TemplateEngineTests {
    @Test func bundleHas42StableTemplatesAndAllDefaultsCompile() throws {
        let engine = try TemplateEngine()
        #expect(engine.templates.count == 42)
        #expect(Set(engine.templates.map(\.id)).count == 42)
        #expect(engine.templates.first?.id == "rain-podcast")
        #expect(engine.templates.map(\.id) == [
            "rain-podcast", "tech-podcast", "knowledge-podcast", "heart-podcast", "intro-podcast", "weekend-podcast",
            "tech-ad", "coffee-ad", "event-ad", "brand-story-ad", "sale-ad", "sound-logo-ad",
            "rooftop-story", "forest-audiobook", "mystery-audiobook", "fairytale-audiobook", "history-audiobook", "essay-audiobook",
            "ancient-drama", "family-drama", "midnight-store", "airlock-drama", "comedy-drama", "reunion-drama",
            "village-elder", "dungeon-merchant", "battle-game", "repair-game", "explore-game", "victory-game",
            "ai-narration", "nature-narration", "tutorial-narration", "travel-narration", "course-narration", "biography-narration",
            "custom-scene", "duo-scene", "trio-scene", "ambience-scene", "custom-logo", "music-scene"
        ])
        for mode in CreationMode.allCases { #expect(engine.templates.filter { $0.mode == mode }.count == 6) }
        for template in engine.templates {
            let preview = try engine.preview(templateID: template.id, values: [:])
            #expect(!preview.prompt.contains("{{"))
            #expect(preview.compiled.scalarCount <= 3000)
            let compiled = try PromptCompiler.compile(mode: template.mode, prompt: preview.prompt, bindings: [])
            #expect(preview.compiled == compiled)
        }
    }

    @Test func textValuesRejectUnknownOverlongUnresolvedAndSensitiveInput() throws {
        let engine = try TemplateEngine()
        #expect(try engine.preview(templateID: "rain-podcast", values: ["show": .text("我的节目")]).prompt.contains("《我的节目》"))
        for values: [String: TemplateValue] in [
            ["unknown": .text("a")], ["show": .text(String(repeating: "🎵", count: 81))],
            ["show": .text("{{other}}")], ["show": .text(" ")], ["show": .number(1)],
            ["show": .text("sk-" + String(repeating: "x", count: 24))],
            ["show": .text("data:audio/wav;base64,AAAA")], ["show": .text("llm-abcdefgh1234")]
        ] { #expect(throws: TemplateError.self) { try engine.preview(templateID: "rain-podcast", values: values) } }
        #expect(throws: TemplateError.self) { try engine.preview(templateID: "missing", values: [:]) }
    }

    @Test func numberAndSelectEnforceTypesBoundsAndOptions() throws {
        let item = StudioTemplate(id: "custom-test", name: "测试", mode: .auto,
            promptPattern: "{{count}} 次 {{style}}", variables: [
                .init(key: "count", label: "次数", type: .number, defaultValue: .number(2), min: 1, max: 3),
                .init(key: "style", label: "风格", type: .select, defaultValue: .text("自然"), options: ["自然", "轻快"])
            ])
        let engine = try TemplateEngine(templates: [item])
        #expect(try engine.preview(templateID: item.id, values: [:]).prompt == "2 次 自然")
        for values: [String: TemplateValue] in [["count": .number(4)], ["count": .number(.infinity)], ["count": .text("2")], ["style": .text("未知")]] {
            #expect(throws: TemplateError.self) { try engine.preview(templateID: item.id, values: values) }
        }
    }

    @Test func invalidDefinitionsAndExpandedLengthFail() throws {
        for pattern in ["{{unknown}}", "{{x + 1}}", "hello }}", "data:audio/wav;base64,AAAA"] {
            #expect(throws: TemplateError.self) { try TemplateEngine(templates: [.init(id: "bad", name: "坏模板", mode: .auto, promptPattern: pattern)]) }
        }
        let item = StudioTemplate(id: "long", name: "长模板", mode: .auto, promptPattern: "{{x}}{{x}}{{x}}", variables: [
            .init(key: "x", label: "文字", type: .text, defaultValue: .text("短"), maxLength: 1000)
        ])
        let engine = try TemplateEngine(templates: [item])
        #expect(throws: PromptValidationError.tooLong) { try engine.preview(templateID: item.id, values: ["x": .text(String(repeating: "字", count: 1000))]) }
    }

    @Test func metadataAndDefaultsCannotHideSensitiveOrInvalidDefinitions() throws {
        let base = StudioTemplate(name: "有效模板", mode: .auto, promptPattern: "{{x}}", variables: [
            .init(key: "x", label: "标签", type: .text, defaultValue: .text("正常"))
        ])
        var variants: [StudioTemplate] = []
        var item = base; item.name = "sk-" + String(repeating: "a", count: 24); variants.append(item)
        item = base; item.variables[0].defaultValue = .text("{{x}}"); variants.append(item)
        item = base; item.variables[0].maxLength = 0; variants.append(item)
        item = base; item.variables.append(item.variables[0]); variants.append(item)
        item = base; item.variables[0].type = .number; item.variables[0].defaultValue = .number(.nan); variants.append(item)
        item = base; item.variables[0].type = .number; item.variables[0].min = 3; item.variables[0].max = 1; variants.append(item)
        item = base; item.variables[0].type = .select; item.variables[0].options = []; variants.append(item)
        for invalid in variants { #expect(throws: TemplateError.self) { try TemplateEngine(templates: [invalid]) } }
        let engine = try TemplateEngine(templates: [base])
        #expect(try engine.preview(templateID: base.id, values: ["x": .text(#"$1\literal"#)]).prompt == #"$1\literal"#)
    }

    @Test func customVoicePreviewRequiresActualStableBinding() throws {
        let item = StudioTemplate(name: "音色模板", mode: .drama, promptPattern: "@voice2 你好")
        let engine = try TemplateEngine(templates: [item])
        #expect(throws: PromptValidationError.self) { try engine.preview(templateID: item.id, values: [:]) }
        let bindings = [ReferenceBinding(referenceID: "a", alias: "甲", slot: 1), ReferenceBinding(referenceID: "b", alias: "乙", slot: 2)]
        let result = try engine.preview(templateID: item.id, values: [:], bindings: bindings.reversed())
        #expect(result.compiled.bindings == bindings)
        #expect(result.compiled.text.hasSuffix("参考音色：按 @voice1 到 @voice2 的编号使用参考音频。"))
    }

    @Test func storeProtectsBuiltinsAndSupportsSessionCRUDAndFavorites() async throws {
        let store = try InMemoryTemplateStore()
        let builtin = try #require(try await store.list().first)
        await #expect(throws: TemplateError.readOnly) { try await store.save(builtin) }
        await #expect(throws: TemplateError.readOnly) { try await store.remove(id: builtin.id) }
        var custom = StudioTemplate(id: "user-test", name: "自己的模板", mode: .auto, promptPattern: "你好")
        try await store.save(custom)
        custom.name = "修改名称"
        try await store.save(custom)
        try await store.setFavorite(id: custom.id, favorite: true)
        #expect(try await store.favorites() == [custom.id])
        #expect(try await store.list().first { $0.id == custom.id }?.name == "修改名称")
        try await store.remove(id: custom.id)
        #expect(try await store.list().count == 42)
        #expect(try await store.favorites().isEmpty)
    }

    @MainActor @Test func applyingTemplateUndoAndRedoRestoreDraftFields() throws {
        let before = DraftFields(name: "之前", mode: .game, prompt: "原稿🎵")
        let draft = DraftController(fields: before, store: InMemoryDraftStore())
        let application = TemplateApplicationController(draft: draft)
        let preview = try TemplateEngine().preview(templateID: "rain-podcast", values: [:])
        application.apply(preview)
        #expect(draft.fields.prompt == preview.prompt)
        #expect(draft.fields.mode == .podcast)
        application.undoManager.undo()
        #expect(draft.fields == before)
        application.undoManager.redo()
        #expect(draft.fields.prompt == preview.prompt)
    }

    @MainActor @Test func applyingIdenticalSampleWithDifferentModePreservesExactPreview() throws {
        let draft = DraftController(store: InMemoryDraftStore())
        let original = draft.fields
        let template = StudioTemplate(name: "相同正文的新模式", mode: .game, promptPattern: original.prompt)
        let preview = try TemplateEngine(templates: [template]).preview(templateID: template.id, values: [:])
        let application = TemplateApplicationController(draft: draft)
        application.apply(preview)
        #expect(draft.fields.prompt == preview.prompt)
        #expect(draft.fields.mode == .game)
        application.undoManager.undo()
        #expect(draft.fields == original)
    }
}
