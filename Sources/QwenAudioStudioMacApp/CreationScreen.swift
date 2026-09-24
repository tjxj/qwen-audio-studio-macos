import SwiftUI
import StudioCore
import AppKit

struct CreationScreen: View {
    @Environment(OutputFolderController.self) private var outputFolders
    @State private var outputFolderName = "尚未选择输出目录"
    @State private var showsVoiceSheet = false
    let draft: DraftController
    var sharedUndoManager: UndoManager? = nil
    @Environment(StudioPreferences.self) private var preferences
    var editor = PromptEditorHandle()
    var appState: AppState? = nil
    @FocusState private var titleFocused: Bool

    private func field<Value>(_ key: WritableKeyPath<DraftFields, Value>) -> Binding<Value> {
        Binding(get: { draft.fields[keyPath: key] }, set: { value in draft.change { $0[keyPath: key] = value } })
    }
    private var canGenerate: Bool {
        appState != nil && appState?.preparing != true && appState?.submitting != true && draft.state != .conflict
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            modes
            editorCard
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .background(StudioPalette.background)
        .navigationTitle("创作台")
        .task { editor.focus(); if appState == nil { try? await draft.saveNow() } }
        .sheet(isPresented: Binding(get: { appState?.generationPlan != nil }, set: { if !$0 { appState?.generationPlan = nil } })) {
            if let appState, let plan = appState.generationPlan {
                GenerationSheet(plan: plan, directoryName: outputFolderName, service: appState.generation,
                    onConfirm: { hash, id in appState.submit(plan: plan, hash: hash, requestID: id) },
                    onCancel: { appState.generationPlan = nil })
            }
        }
        .sheet(isPresented: $showsVoiceSheet) {
            if let service = outputFolders.referenceAudio { VoiceSheet(controller: VoiceSheetController(service: service), draft: draft) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { try? await draft.saveNow() } } label: {
                    Label("保存草稿", systemImage: "square.and.arrow.down")
                }
                .disabled(draft.state == .conflict)
                .help("保存到本地作品库（⌘S）")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("作品名称", text: field(\.name))
                .textFieldStyle(.plain)
                .font(StudioTypography.serif(28))
                .focused($titleFocused)
                .onSubmit { editor.focus() }
                .accessibilityIdentifier("draft-name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Label(saveTitle, systemImage: saveSymbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(draft.state == .conflict ? Color.orange : .secondary)
                .fixedSize()
            if let appState {
                Menu {
                    Button("空白草稿") { Task { await appState.newBlankDraft() } }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("草稿操作")
                    .accessibilityLabel("草稿操作")
            }
        }
        .frame(height: 42)
    }

    private var saveTitle: String {
        switch draft.state {
        case .unsaved: "有未保存更改"
        case .saving: "正在暂存…"
        case .saved: "已保存到本地"
        case .conflict: "版本冲突 · 本地稿已保留"
        case .failed: "暂存失败 · 可重试"
        }
    }
    private var saveSymbol: String {
        switch draft.state {
        case .saved: "checkmark.circle"
        case .conflict, .failed: "exclamationmark.triangle"
        case .saving: "arrow.triangle.2.circlepath"
        case .unsaved: "circle.dotted"
        }
    }

    private var modes: some View {
        HStack(spacing: 7) {
            ForEach(CreationMode.allCases) { mode in
                Button { draft.change { $0.mode = mode } } label: {
                    Label(mode.title, systemImage: mode.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .foregroundStyle(draft.fields.mode == mode ? .white : .primary)
                        .background(draft.fields.mode == mode ? StudioPalette.green : StudioPalette.surface,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioPalette.stroke))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(draft.fields.mode == mode ? [.isSelected] : [])
            }
        }
    }

    private var editorCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                scriptPane
                Divider()
                ParameterInspector(params: field(\.params), onAddVoice: { showsVoiceSheet = true }).frame(width: 258)
            }
            .frame(maxHeight: .infinity)
            if draft.state == .conflict {
                HStack {
                    Text("本地文本仍可编辑。可复制恢复稿，或另存为新草稿。")
                    Spacer()
                    Button("复制恢复稿") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft.localRecoveryText ?? draft.fields.prompt, forType: .string)
                    }
                    Button("另存新草稿") { Task { try? await draft.saveRecoveryAsNewDraft() } }
                }
                .font(.caption).padding(10)
            }
            Divider()
            footer
        }
        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioPalette.stroke))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .frame(maxHeight: .infinity)
    }

    private var scriptPane: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("创作脚本").font(StudioTypography.serif(20))
                Spacer()
                Text("⌘Z 撤销").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                insertButton("角色", tag: "【角色：讲述者】")
                insertButton("对白", tag: "【对白：讲述者】")
                insertButton("时间戳", tag: "【00:00】")
                insertButton("音效", tag: "【音效】")
                insertButton("音乐", tag: "【音乐】")
                Button { showsVoiceSheet = true } label: { Label("音色", systemImage: "person.wave.2") }
                    .font(.system(size: 11)).disabled(outputFolders.referenceAudio == nil)
                ForEach(draft.fields.referenceBindings, id: \.referenceID) { binding in
                    insertButton("@voice\(binding.slot)", tag: "@voice\(binding.slot)")
                }
                Spacer(minLength: 0)
            }
            PromptEditor(text: field(\.prompt), font: preferences.scriptFont.font(size: preferences.scriptSize), handle: editor, sharedUndoManager: sharedUndoManager)
                .background(StudioPalette.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioPalette.stroke))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .frame(minHeight: 100, maxHeight: .infinity)
            HStack {
                Text("编辑后切换模式，保留你的脚本")
                Spacer()
                Text("\(draft.fields.prompt.unicodeScalars.count) 字").monospacedDigit()
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func insertButton(_ title: String, tag: String) -> some View {
        Button(title) { editor.insert(tag) }
            .font(.system(size: 11))
            .buttonStyle(.bordered)
            .help("在光标或选区插入\(title)标签，可撤销")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button { Task {
                        let current = draft.fields.outputDirectoryID ?? outputFolders.defaultID
                        if let id = await outputFolders.choose(currentID: current), id != current {
                            draft.change { $0.outputDirectoryID = id }
                            outputFolderName = (try? await outputFolders.name(for: id)) ?? "请重新授权输出目录"
                        }
                    } } label: { Label(outputFolderName, systemImage: "folder").lineLimit(1) }
                        .disabled(outputFolders.directories == nil || outputFolders.isChoosing)
                    if let id = draft.fields.outputDirectoryID ?? outputFolders.defaultID {
                        Menu {
                            Button("在 Finder 显示") { Task { await outputFolders.revealDirectory(id) } }
                            Button("重新授权原文件夹…") { Task {
                                if await outputFolders.reauthorize(id) {
                                    outputFolderName = (try? await outputFolders.name(for: id)) ?? "请重新授权输出目录"
                                }
                            } }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .disabled(outputFolders.isChoosing)
                            .help("输出文件夹操作")
                    }
                }
                .task(id: draft.fields.outputDirectoryID ?? outputFolders.defaultID) {
                    if let id = draft.fields.outputDirectoryID ?? outputFolders.defaultID {
                        outputFolderName = (try? await outputFolders.name(for: id)) ?? "请重新授权输出目录"
                    } else { outputFolderName = "尚未选择输出目录" }
                }
                if let message = outputFolders.errorMessage { Text(message).font(.caption).foregroundStyle(.red).lineLimit(2) }
                if let appState, appState.submitting {
                    let stages = appState.jobStage.values.map(\.rawValue).sorted().joined(separator: " · ")
                    Text(stages.isEmpty ? "正在建立任务记录…" : "任务阶段：\(stages)")
                        .font(.system(size: 10)).lineLimit(1)
                }
                if let error = appState?.errorMessage { Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2) }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            if let appState {
                if appState.submitting, appState.activeBatchID != nil {
                    Button("取消未开始候选") { Task { await appState.cancelRemaining() } }
                        .font(.system(size: 11)).buttonStyle(.borderless)
                }
                Picker("候选数", selection: Binding(get: { appState.candidateCount }, set: { appState.candidateCount = $0; preferences.defaultCandidates = $0 })) {
                    ForEach(1...3, id: \.self) { Text("\($0) 个候选").tag($0) }
                }.frame(width: 150)
            }
            Button { Task { await appState?.preflight() } } label: {
                Label(appState?.preparing == true ? "正在预检" : appState?.submitting == true ? "正在生成" : "生成音频", systemImage: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 126, height: 31)
                    .foregroundStyle(canGenerate ? Color.white : Color.secondary)
                    .background(canGenerate ? StudioPalette.green : Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(!canGenerate)
            .help("预检后确认调用次数与可能费用")
        }
        .padding(.horizontal, 18)
        .frame(height: 63)
    }
}
