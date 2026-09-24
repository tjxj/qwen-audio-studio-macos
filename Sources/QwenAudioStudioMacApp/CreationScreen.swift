import SwiftUI
import StudioCore
import AppKit

struct CreationScreen: View {
    let draft: DraftController
    var sharedUndoManager: UndoManager? = nil
    @Environment(StudioPreferences.self) private var preferences
    var editor = PromptEditorHandle()
    @FocusState private var titleFocused: Bool

    private func field<Value>(_ key: WritableKeyPath<DraftFields, Value>) -> Binding<Value> {
        Binding(get: { draft.fields[keyPath: key] }, set: { value in draft.change { $0[keyPath: key] = value } })
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
        .task { editor.focus(); try? await draft.saveNow() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { try? await draft.saveNow() } } label: {
                    Label("保存草稿", systemImage: "square.and.arrow.down")
                }
                .disabled(draft.state == .conflict)
                .help("暂存当前会话的草稿（⌘S）")
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
        }
        .frame(height: 42)
    }

    private var saveTitle: String {
        switch draft.state {
        case .unsaved: "有未保存更改"
        case .saving: "正在暂存…"
        case .saved: "已暂存 · 本次会话"
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
                ParameterInspector(params: field(\.params)).frame(width: 258)
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
                Label("尚未选择输出目录", systemImage: "folder")
                Text("草稿暂存在内存，关闭应用后不保留。")
                    .font(.system(size: 10))
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text("候选 1").font(.system(size: 12)).foregroundStyle(.secondary)
            Button {} label: {
                Label("生成音频", systemImage: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 126, height: 31)
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)
            .help("生成服务将在后续版本接入")
        }
        .padding(.horizontal, 18)
        .frame(height: 63)
    }
}
