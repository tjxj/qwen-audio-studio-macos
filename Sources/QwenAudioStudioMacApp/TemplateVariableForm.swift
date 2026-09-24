import SwiftUI
import StudioCore
import Observation

@MainActor @Observable final class TemplateVariableForm {
    struct Row: Identifiable {
        let id = UUID().uuidString
        var variable: TemplateVariable
    }
    var rows: [Row]
    var variables: [TemplateVariable] { rows.map(\.variable) }
    init(variables: [TemplateVariable]) { rows = variables.map { Row(variable: $0) } }
    func remove(id: String) { rows.removeAll { $0.id == id } }
    func add() {
        var number = 1
        while variables.contains(where: { $0.key == "value\(number)" }) { number += 1 }
        rows.append(Row(variable: .init(key: "value\(number)", label: "新变量", type: .text, defaultValue: .text("示例"), maxLength: 200)))
    }
}

struct TemplateVariableFields: View {
    @Bindable var form: TemplateVariableForm
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach($form.rows) { $row in
                    TemplateVariableRow(variable: $row.variable) { form.remove(id: row.id) }
                }
                Button("添加变量", systemImage: "plus") { form.add() }.disabled(form.rows.count >= 20)
            }
        }
    }
}

private struct TemplateVariableRow: View {
    @Binding var variable: TemplateVariable
    let onRemove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("变量名", text: $variable.key).frame(width: 145)
                TextField("显示名称", text: $variable.label)
                Picker("类型", selection: $variable.type) {
                    Text("文本").tag(TemplateVariable.Kind.text)
                    Text("数字").tag(TemplateVariable.Kind.number)
                    Text("选项").tag(TemplateVariable.Kind.select)
                }.frame(width: 135)
                Button("删除", role: .destructive, action: onRemove)
            }
            HStack {
                TextField("默认值", text: Binding(get: { variable.defaultValue.display }, set: {
                    variable.defaultValue = variable.type == .number ? .number(Double($0) ?? .nan) : .text($0)
                }))
                Toggle("必填", isOn: $variable.required)
                if variable.type == .number {
                    TextField("最小值", value: $variable.min, format: .number).frame(width: 90)
                    TextField("最大值", value: $variable.max, format: .number).frame(width: 90)
                } else {
                    Text("长度").font(.caption)
                    TextField("200", value: $variable.maxLength, format: .number).frame(width: 60)
                }
            }
            if variable.type == .select {
                TextField("选项以中文逗号分隔", text: Binding(get: { (variable.options ?? []).joined(separator: "，") }, set: {
                    variable.options = $0.components(separatedBy: "，")
                }))
            }
        }.padding(10).background(StudioPalette.background, in: RoundedRectangle(cornerRadius: 8))
    }
}
