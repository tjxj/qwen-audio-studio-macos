import SwiftUI

struct SettingsScreen: View {
    @State private var apiKey = ""
    @State private var workspaceID = ""

    var body: some View {
        Form {
            Section("百炼连接") {
                SecureField("API Key", text: $apiKey)
                    .disabled(true)
                TextField("Workspace ID", text: $workspaceID)
                    .disabled(true)
                Text("凭据存储将在后续阶段接入。当前字段不会保存或发起请求。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("文件与存储") {
                LabeledContent("默认输出目录", value: "尚未选择")
                LabeledContent("本地作品库", value: "尚未初始化")
            }

            Section("外观") {
                LabeledContent("主题", value: "跟随系统")
                Text("支持系统深色外观；手动主题设置将在后续阶段接入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 650, height: 500)
        .navigationTitle("设置")
    }
}
