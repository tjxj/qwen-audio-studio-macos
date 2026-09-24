import SwiftUI
import StudioCore

struct SettingsScreen: View {
    var state: AppState? = nil
    var qaMode = false
    @Environment(StudioPreferences.self) private var preferences
    @Environment(OutputFolderController.self) private var outputFolders
    @State private var apiKey = ""
    @State private var workspaceID = ""
    @State private var credentialStatus = "凭据尚未检查"
    @State private var environmentStatus = "尚未检查"
    @State private var localRecordCount = 0
    private let credentials = NativeCredentialStore()

    var body: some View {
        @Bindable var preferences = preferences
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text("设置").font(StudioTypography.serif(27))
                Spacer()
                Text("qwen-audio-3.1-tts-next · 北京地域")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 13) {
                    Label("百炼连接", systemImage: "key.horizontal").font(.headline)
                    Text("API Key 与业务空间 ID 分开保存。已存密钥不会回填到界面。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    SecureField("输入北京地域 API Key", text: $apiKey).disabled(qaMode)
                    Button("保存 API Key") {
                        do { try credentials.saveAPIKey(apiKey); apiKey = ""; refreshCredentialStatus() }
                        catch { credentialStatus = "API Key 保存失败，请检查输入或钥匙串权限。" }
                    }.disabled(apiKey.isEmpty || qaMode)
                    Divider()
                    TextField("输入 Workspace ID", text: $workspaceID).disabled(qaMode)
                    Button("保存 Workspace ID") {
                        do { try credentials.saveWorkspaceID(workspaceID); workspaceID = ""; refreshCredentialStatus() }
                        catch { credentialStatus = "Workspace ID 保存失败，请检查格式或钥匙串权限。" }
                    }.disabled(workspaceID.isEmpty || qaMode)
                    Divider()
                    Text(credentialStatus).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("读取已有本地配置") {
                        do {
                            let imported = try credentials.importLegacy()
                            credentialStatus = imported.apiKey || imported.workspaceID
                                ? "已读取旧版本地配置。\(imported.failed ? "部分字段保存失败，请分别检查。" : "旧条目保留。")"
                                : "未找到旧版配置；请手动填写。"
                        } catch { credentialStatus = "读取旧版配置失败；已保存字段保留。" }
                    }.disabled(qaMode)
                    Divider()
                    Text("准备凭据").font(.caption.weight(.semibold))
                    Link("获取 API Key ↗", destination: URL(string: "https://help.aliyun.com/zh/model-studio/get-api-key")!)
                    Link("查找 Workspace ID ↗", destination: URL(string: "https://help.aliyun.com/zh/model-studio/obtain-the-app-id-and-workspace-id")!)
                    Link("Next 音频 API 说明 ↗", destination: URL(string: "https://help.aliyun.com/zh/model-studio/audio-generation-api")!)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .padding(17)
                .frame(width: 310).frame(maxHeight: .infinity, alignment: .topLeading)
                .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(StudioPalette.stroke))

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("文件与存储", systemImage: "folder").font(.headline)
                        Text(outputFolders.defaultName).font(.caption).lineLimit(1)
                        HStack(spacing: 8) {
                            Button("选择文件夹…") { Task { await outputFolders.chooseDefault() } }
                                .disabled(outputFolders.directories == nil || outputFolders.isChoosing)
                            if let id = outputFolders.defaultID {
                                Button("重新授权") { Task { _ = await outputFolders.reauthorize(id) } }
                                    .disabled(outputFolders.isChoosing)
                                Button("Finder") { Task { await outputFolders.revealDirectory(id) } }
                            }
                        }
                        if let message = outputFolders.errorMessage { Text(message).foregroundStyle(.red).font(.caption) }
                        Divider()
                        Text("本地库：\(state == nil ? "暂不可用" : "已连接") · \(localRecordCount) 条生成记录")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("检查本地环境") { Task { await checkEnvironment() } }
                        Text(environmentStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.card()

                    VStack(alignment: .leading, spacing: 8) {
                        Label("新作品默认值", systemImage: "slider.horizontal.3").font(.headline)
                        HStack {
                            Picker("格式", selection: $preferences.defaultFormat) {
                                Text("WAV").tag("wav"); Text("MP3").tag("mp3"); Text("PCM").tag("pcm")
                            }
                            Picker("采样率", selection: $preferences.defaultSampleRate) {
                                ForEach([8000, 16000, 24000, 44100, 48000], id: \.self) { Text("\($0) Hz").tag($0) }
                            }
                        }
                        Picker("候选数", selection: $preferences.defaultCandidates) {
                            ForEach(1...3, id: \.self) { Text("\($0) 个").tag($0) }
                        }
                        Picker("同时生成", selection: $preferences.defaultConcurrency) {
                            ForEach(1...3, id: \.self) { Text("\($0) 路").tag($0) }
                        }
                        Text("只影响新草稿；生成前会确认实际调用次数。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.card()

                    VStack(alignment: .leading, spacing: 8) {
                        Label("外观与阅读", systemImage: "paintbrush").font(.headline)
                        HStack {
                            Picker("主题", selection: $preferences.appearance) {
                                ForEach(StudioAppearance.allCases) { Text($0.title).tag($0) }
                            }
                            Picker("字体", selection: $preferences.scriptFont) {
                                ForEach(ScriptFont.allCases) { Text($0.title).tag($0) }
                            }
                        }
                        Slider(value: $preferences.scriptSize, in: 14...26, step: 1) {
                            Text("脚本字号 \(Int(preferences.scriptSize))")
                        }
                    }.card()
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxHeight: .infinity)
            Text("环境检查只读取本机状态，不会发送收费模型请求。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 780, height: 590)
        .background(StudioPalette.background)
        .onAppear { if qaMode { credentialStatus = "演示模式：未读取钥匙串" } else { refreshCredentialStatus() } }
        .onChange(of: preferences.defaultConcurrency) { _, value in
            if let state { Task { await state.generation.setMaxConcurrentJobs(value) } }
        }
    }

    private func refreshCredentialStatus() {
        do {
            let key = try credentials.hasAPIKey()
            let workspace = try credentials.workspaceID() != nil
            credentialStatus = "API Key：\(key ? "已保存" : "未设置") · Workspace ID：\(workspace ? "已保存" : "未设置")"
        } catch { credentialStatus = "钥匙串读取失败，请检查本机权限。" }
    }
    private func checkEnvironment() async {
        if !qaMode { refreshCredentialStatus() }
        guard let state else { environmentStatus = "本地库未连接，请关闭重复运行的应用后重试。"; return }
        do {
            localRecordCount = try await state.store.listLibrary().count
            _ = try await state.store.listProjects()
            environmentStatus = "SQLite 与原生音频模块可用。"
        } catch { environmentStatus = "本地环境检查失败，请检查磁盘与权限。" }
    }
}

private extension View {
    func card() -> some View {
        self.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioPalette.stroke))
    }
}
