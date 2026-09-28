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
        VStack(alignment: .leading, spacing: 12) {
            topBar
            editorCard
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .background(StudioPalette.background)
        .navigationTitle("创作台")
        .task { editor.focus(); if appState == nil { try? await draft.saveNow() } }
        .sheet(isPresented: Binding(
            get: { (appState?.generationPlan != nil) || (appState?.isShowingGenerationOverlay == true) },
            set: { if !$0 {
                appState?.generationPlan = nil
                appState?.isShowingGenerationOverlay = false
            } }
        )) {
            if let appState {
                GenerationSheet(
                    plan: appState.generationPlan,
                    directoryName: outputFolderName,
                    appState: appState,
                    onDismiss: {
                        appState.generationPlan = nil
                        appState.isShowingGenerationOverlay = false
                    },
                    onNavigateToLibrary: {
                        appState.selectedPage = .library
                    }
                )
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

    private var topBar: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 10) {
                TextField("作品名称", text: field(\.name))
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .bold))
                    .focused($titleFocused)
                    .onSubmit { editor.focus() }
                    .accessibilityIdentifier("draft-name")
                    .frame(minWidth: 140, maxWidth: 260, alignment: .leading)
                Label(saveTitle, systemImage: saveSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(draft.state == .conflict ? Color.orange : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.04), in: Capsule())
                    .fixedSize()
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                modes
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
        }
        .frame(height: 34)
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
        HStack(spacing: 4) {
            ForEach(CreationMode.allCases) { mode in
                let isSelected = draft.fields.mode == mode
                Button { draft.change { $0.mode = mode } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        Text(mode.title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
                    .background(isSelected ? StudioPalette.green : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(StudioPalette.surface, in: Capsule())
        .overlay(Capsule().stroke(StudioPalette.stroke))
    }

    private var editorCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                scriptPane
                Divider()
                ParameterInspector(params: field(\.params), onAddVoice: { showsVoiceSheet = true }).frame(width: 268)
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
        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioPalette.stroke))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxHeight: .infinity)
    }

    private var scriptPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    tagChip("角色", tag: "【角色：讲述者】", color: Color.blue)
                    tagChip("对白", tag: "【对白：讲述者】", color: Color.teal)
                    tagChip("时间戳", tag: "【00:00】", color: Color.secondary)
                    tagChip("音效", tag: "【音效】", color: Color.purple)
                    tagChip("音乐", tag: "【音乐】", color: Color.indigo)
                    Button { showsVoiceSheet = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "person.wave.2")
                            Text("音色")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(StudioPalette.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(StudioPalette.green)
                    }
                    .buttonStyle(.plain)
                    .disabled(outputFolders.referenceAudio == nil)
                    ForEach(draft.fields.referenceBindings, id: \.referenceID) { binding in
                        tagChip("@voice\(binding.slot)", tag: "@voice\(binding.slot)", color: StudioPalette.green)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Button {
                        preferences.scriptSize = max(14, preferences.scriptSize - 1)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                            .font(.system(size: 11))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("减小脚本字号")

                    Text("\(Int(preferences.scriptSize)) pt")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36)

                    Button {
                        preferences.scriptSize = min(28, preferences.scriptSize + 1)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                            .font(.system(size: 11))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("增大脚本字号")
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)

            PromptEditor(text: field(\.prompt), font: preferences.scriptFont.font(size: preferences.scriptSize), handle: editor, sharedUndoManager: sharedUndoManager)
                .frame(minHeight: 100, maxHeight: .infinity)

            HStack {
                Text("输入【可呼出标记 · 切换模式保留脚本")
                Spacer()
                Text("\(draft.fields.prompt.unicodeScalars.count) 字").monospacedDigit()
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tagChip(_ title: String, tag: String, color: Color) -> some View {
        Button {
            editor.insert(tag)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .help("在光标或选区插入\(title)标签")
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
