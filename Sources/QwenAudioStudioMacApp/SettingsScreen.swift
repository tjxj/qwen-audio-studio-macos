import SwiftUI
import StudioCore

struct SettingsScreen: View {
    @Environment(StudioPreferences.self) private var preferences
    @Environment(OutputFolderController.self) private var outputFolders
    @State private var apiKey = ""
    @State private var workspaceID = ""
    @State private var credentialStatus = "凭据尚未检查"
    private let credentials = NativeCredentialStore()

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section("百炼连接") {
                SecureField("API Key", text: $apiKey)
                    .textContentType(.password)
                Button("保存 API Key") {
                    do { try credentials.saveAPIKey(apiKey); apiKey = ""; refreshCredentialStatus() }
                    catch { credentialStatus = "API Key 保存失败，请检查输入或钥匙串权限。" }
                }.disabled(apiKey.isEmpty)
                TextField("Workspace ID", text: $workspaceID)
                Button("保存 Workspace ID") {
                    do { try credentials.saveWorkspaceID(workspaceID); workspaceID = ""; refreshCredentialStatus() }
                    catch { credentialStatus = "Workspace ID 保存失败，请检查格式或钥匙串权限。" }
                }.disabled(workspaceID.isEmpty)
                Button("读取已有本地配置") {
                    do {
                        let imported = try credentials.importLegacy()
                        let suffix = imported.failed ? "部分字段保存失败，请单独检查并填写；已保存字段保留。" : "旧条目保留。"
                        credentialStatus = imported.apiKey || imported.workspaceID ? "已读取旧版本地配置。\(suffix)" : "未找到可读取的旧版配置，或保存失败；请手动填写。"
                    } catch { credentialStatus = "读取旧版配置失败，请手动填写；已保存字段保留。" }
                }
                Link("查看百炼 API 配置说明", destination: URL(string: "https://help.aliyun.com/zh/model-studio/audio-generation-api")!)
                Text(credentialStatus)
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
        .onAppear(perform: refreshCredentialStatus)
    }

    private func refreshCredentialStatus() {
        do {
            let key = try credentials.hasAPIKey()
            let workspace = try credentials.workspaceID() != nil
            credentialStatus = "API Key：\(key ? "已保存" : "未设置") · Workspace ID：\(workspace ? "已保存" : "未设置")"
        } catch { credentialStatus = "钥匙串读取失败，请检查本机权限。" }
    }
}
