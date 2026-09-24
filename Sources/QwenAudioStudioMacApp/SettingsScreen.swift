import SwiftUI

struct SettingsScreen: View {
    @Environment(StudioPreferences.self) private var preferences
    @Environment(OutputFolderController.self) private var outputFolders
    @State private var apiKey = ""
    @State private var workspaceID = ""

    var body: some View {
        @Bindable var preferences = preferences
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
                LabeledContent("默认输出目录") {
                    Text(outputFolders.defaultName).lineLimit(1)
                    Button("选择…") { Task { await outputFolders.chooseDefault() } }
                        .disabled(outputFolders.directories == nil || outputFolders.isChoosing)
                    if let id = outputFolders.defaultID {
                        Button("重新授权…") { Task { _ = await outputFolders.reauthorize(id) } }
                            .disabled(outputFolders.isChoosing)
                        Button("在 Finder 显示") { Task { await outputFolders.revealDirectory(id) } }
                    }
                }
                if let message = outputFolders.errorMessage { Text(message).font(.caption).foregroundStyle(.red) }
                LabeledContent("本地作品库", value: "尚未初始化")
            }

            Section("外观") {
                Picker("主题", selection: $preferences.appearance) {
                    ForEach(StudioAppearance.allCases) { Text($0.title).tag($0) }
                }
                Picker("脚本字体", selection: $preferences.scriptFont) {
                    ForEach(ScriptFont.allCases) { Text($0.title).tag($0) }
                }
                Slider(value: $preferences.scriptSize, in: 14...26, step: 1) {
                    Text("脚本字号 \(Int(preferences.scriptSize))")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 650, height: 500)
        .navigationTitle("设置")
    }
}
