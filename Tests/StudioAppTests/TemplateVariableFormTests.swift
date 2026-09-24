import Testing
import StudioCore
@testable import QwenAudioStudioMacApp

@MainActor struct TemplateVariableFormTests {
    @Test func editingKeyKeepsRowIdentityAndDeletionTargetsThatRow() {
        let form = TemplateVariableForm(variables: [
            .init(key: "topic", label: "主题", type: .text, defaultValue: .text("示例")),
            .init(key: "other", label: "另一项", type: .text, defaultValue: .text("保留"))
        ])
        let identity = form.rows[0].id
        form.rows[0].variable.key = "topic_two"
        form.rows[0].variable.defaultValue = .text("继续输入")
        #expect(form.rows[0].id == identity)
        #expect(form.variables[0].key == "topic_two")
        #expect(form.variables[0].defaultValue == .text("继续输入"))
        form.remove(id: identity)
        #expect(form.variables.map(\.key) == ["other"])
    }
}
