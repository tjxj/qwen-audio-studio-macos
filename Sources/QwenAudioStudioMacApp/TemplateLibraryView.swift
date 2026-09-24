import SwiftUI
import StudioCore
import Observation

@MainActor @Observable
final class TemplateLibraryController {
    private let store: (any TemplateStore)?
    private(set) var templates: [StudioTemplate] = []
    private(set) var favorites: Set<String> = []
    private(set) var lastRemoved: StudioTemplate?
    private var lastRemovedWasFavorite = false
    var error: String?

    init(store: (any TemplateStore)? = nil) {
        do { self.store = try store ?? InMemoryTemplateStore() }
        catch { self.store = nil; self.error = "模板资源读取失败：\(error.localizedDescription)" }
    }
    func reload() async {
        guard let store else { return }
        do { templates = try await store.list(); favorites = try await store.favorites() }
        catch { self.error = error.localizedDescription }
    }
    func save(_ item: StudioTemplate) async -> Bool {
        guard let store else { return false }
        do { try await store.save(item); await reload(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func remove(_ item: StudioTemplate) async {
        guard let store else { return }
        do {
            let wasFavorite = favorites.contains(item.id)
            try await store.remove(id: item.id)
            lastRemoved = item; lastRemovedWasFavorite = wasFavorite
            await reload()
        }
        catch { self.error = error.localizedDescription }
    }
    func undoLastRemoval() async {
        guard let store, let item = lastRemoved else { return }
        do {
            try await store.save(item)
            if lastRemovedWasFavorite { try await store.setFavorite(id: item.id, favorite: true) }
            lastRemoved = nil; lastRemovedWasFavorite = false
            await reload()
        }
        catch { self.error = error.localizedDescription }
    }
    func favorite(_ item: StudioTemplate) async {
        guard let store else { return }
        do { try await store.setFavorite(id: item.id, favorite: !favorites.contains(item.id)); await reload() }
        catch { self.error = error.localizedDescription }
    }
}

struct TemplateScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var library: TemplateLibraryController
    let application: TemplateApplicationController
    let onApplied: () -> Void
    @State private var selectedID = ProcessInfo.processInfo.arguments.contains("--capture-template=2") ? "tech-podcast" : "rain-podcast"
    @State private var mode: CreationMode?
    @State private var search = ""
    @State private var favoritesOnly = false
    @State private var customOnly = false
    @State private var applying: StudioTemplate?
    @State private var editing: StudioTemplate?
    @State private var removing: StudioTemplate?

    private var filtered: [StudioTemplate] {
        library.templates.filter { item in
            (mode == nil || mode == item.mode) && (!favoritesOnly || library.favorites.contains(item.id)) &&
            (!customOnly || !item.isBuiltin) && (search.isEmpty ||
                ([item.name, item.description] + item.tags).joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
    }
    private var selected: StudioTemplate? { filtered.first(where: { $0.id == selectedID }) ?? filtered.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("从一个灵感开始").font(StudioTypography.serif(32))
                    Text("42 个内置场景 · 自建模板与收藏保存在本机")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if library.lastRemoved != nil {
                    Button("撤销移除", systemImage: "arrow.uturn.backward") { Task { await library.undoLastRemoval() } }
                        .buttonStyle(.borderless)
                }
                Button("自建模板", systemImage: "plus") {
                    editing = StudioTemplate(name: "新模板", mode: mode ?? .podcast, promptPattern: "【对白：讲述者】从这里开始。")
                }.buttonStyle(.bordered)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    category("全部", value: nil)
                    ForEach(CreationMode.allCases) { category($0.title, value: $0) }
                }
            }
            HStack(spacing: 14) {
                TextField("搜索场景、标题或标签", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                Toggle("收藏", isOn: $favoritesOnly).toggleStyle(.checkbox)
                Toggle("我的模板", isOn: $customOnly).toggleStyle(.checkbox)
                Spacer()
                Text("\(filtered.count) 个场景").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(filtered) { card($0) }
                    }
                    if filtered.isEmpty { ContentUnavailableView("没有匹配模板", systemImage: "magnifyingglass", description: Text("调整分类或搜索词，也可以新建自己的模板。")) }
                }.frame(maxWidth: .infinity)
                if let selected { detail(selected).frame(width: 302) }
            }.frame(maxHeight: .infinity)
        }
        .padding(24).background(StudioPalette.background).navigationTitle("灵感模板")
        .task {
            await library.reload()
            if ProcessInfo.processInfo.arguments.contains("--capture-sheet=template") { applying = selected }
        }
        .sheet(item: $applying) { item in
            TemplateApplicationSheet(item: item, application: application) { applying = nil; onApplied() }
        }
        .sheet(item: $editing) { item in
            TemplateEditorSheet(item: item, library: library) { id in selectedID = id; editing = nil }
        }
        .confirmationDialog("移除这个自建模板？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("移除模板", role: .destructive) { if let removing { Task { await library.remove(removing) } }; removing = nil }
        } message: { Text("移除自建模板后，已应用的创作稿会保留。") }
        .alert("模板操作未完成", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("知道了", role: .cancel) { library.error = nil }
        } message: { Text(library.error ?? "") }
    }

    private func category(_ title: String, value: CreationMode?) -> some View {
        Button { mode = value } label: {
            Text(title).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 11).padding(.vertical, 8)
                .foregroundStyle(mode == value ? (colorScheme == .dark ? Color(red: 0.54, green: 0.78, blue: 0.69) : StudioPalette.green) : .primary)
                .background(mode == value ? StudioPalette.green.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(mode == value ? [.isSelected] : [])
    }

    private func card(_ item: StudioTemplate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { selectedID = item.id } label: {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.mode.title + (item.isBuiltin ? " · 内置" : " · 自建")).font(.caption).foregroundStyle(.secondary)
                    Text(item.name).font(StudioTypography.serif(21)).foregroundStyle(.primary).lineLimit(1)
                    Text(item.description.isEmpty ? "自己的声音创作场景" : item.description)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).frame(height: 34, alignment: .topLeading)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack {
                Text(item.suggestedDurationSeconds.map { "建议 \($0) 秒" } ?? "时长按内容而定")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await library.favorite(item) } } label: {
                    Image(systemName: library.favorites.contains(item.id) ? "star.fill" : "star")
                }.buttonStyle(.plain).accessibilityLabel(library.favorites.contains(item.id) ? "取消收藏 \(item.name)" : "收藏 \(item.name)")
            }
        }.padding(15).background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected?.id == item.id ? StudioPalette.green : StudioPalette.stroke, lineWidth: selected?.id == item.id ? 2 : 1))
    }

    private func detail(_ item: StudioTemplate) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("脚本预览 · 默认变量").font(.caption).foregroundStyle(.secondary)
            Text(item.name).font(StudioTypography.serif(24))
            Text(item.description).font(.caption).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                Text(defaultPrompt(item)).font(StudioTypography.serif(15)).lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(maxHeight: .infinity)
            Divider()
            Button("填写变量并应用") { applying = item }.buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button(item.isBuiltin ? "建立副本" : "编辑") {
                    if item.isBuiltin {
                        var copy = item; copy.id = "user-" + UUID().uuidString; copy.source = "user"; copy.version = 1
                        copy.name += " · 副本"; editing = copy
                    } else { editing = item }
                }
                if !item.isBuiltin { Button("移除", role: .destructive) { removing = item } }
            }.buttonStyle(.borderless).font(.caption).foregroundStyle(.primary)
            Text("建议时长仅供创作参考，实际时长以生成音频为准。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(18).background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(StudioPalette.stroke))
    }

    private func defaultPrompt(_ item: StudioTemplate) -> String {
        do { return try TemplateEngine(templates: [item]).preview(templateID: item.id, values: [:], bindings: application.draft.fields.referenceBindings).prompt }
        catch { return error.localizedDescription + "\n\n" + item.promptPattern }
    }
}

private struct TemplateApplicationSheet: View {
    let item: StudioTemplate
    let application: TemplateApplicationController
    let onApplied: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var inputs: [String: String] = [:]
    @State private var confirming = false
    @State private var showCompiled = true
    @State private var applyError: String?
    private var preview: Result<TemplatePreview, Error> {
        Result {
            var values: [String: TemplateValue] = [:]
            for variable in item.variables {
                let text = inputs[variable.key] ?? variable.defaultValue.display
                values[variable.key] = variable.type == .number ? .number(Double(text) ?? .nan) : .text(text)
            }
            return try TemplateEngine(templates: [item]).preview(templateID: item.id, values: values, bindings: application.draft.fields.referenceBindings)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(item.name).font(StudioTypography.serif(27))
            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("填写变量").font(.headline)
                        if item.variables.isEmpty { Text("此模板无需填写变量。").foregroundStyle(.secondary) }
                        ForEach(item.variables) { variable in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(variable.label + (variable.required ? " *" : "")).font(.system(size: 12, weight: .medium))
                                if variable.type == .select {
                                    Picker(variable.label, selection: input(variable)) {
                                        ForEach(variable.options ?? [], id: \.self) { Text($0).tag($0) }
                                    }.labelsHidden()
                                } else { TextField(variable.label, text: input(variable)).textFieldStyle(.roundedBorder) }
                                Text(variable.type == .number ? "范围 \(variable.min.map { String($0) } ?? "不限") — \(variable.max.map { String($0) } ?? "不限")" : "最多 \(variable.maxLength ?? 200) 字")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(width: 218)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Picker("预览", selection: $showCompiled) {
                        Text("最终 Prompt").tag(true); Text("应用的脚本").tag(false)
                    }.pickerStyle(.segmented)
                    switch preview {
                    case .success(let value):
                        ScrollView {
                            Text(showCompiled ? value.compiled.text : value.prompt).font(StudioTypography.serif(15)).lineSpacing(5)
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }.padding(12).background(StudioPalette.background, in: RoundedRectangle(cornerRadius: 8))
                        Text("编译后 \(value.compiled.scalarCount) / 3000 字 · \(item.mode.title)").font(.caption).foregroundStyle(.secondary)
                    case .failure(let error):
                        Text(error.localizedDescription).foregroundStyle(.red).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            if let applyError { Text(applyError).foregroundStyle(.red).font(.caption) }
            HStack {
                Text("应用后可用 ⌘Z 撤销；生成前仍需单独确认。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用到创作台") {
                    if application.draft.fields.prompt.isEmpty { apply() } else { confirming = true }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled((try? preview.get()) == nil)
            }
        }.padding(24).frame(width: 760, height: 520)
        .confirmationDialog("替换当前作品名称、模式和脚本？", isPresented: $confirming, titleVisibility: .visible) {
            Button("替换并应用") { apply() }
            Button("取消", role: .cancel) {}
        } message: { Text("音色绑定和输出参数会保留。应用后可以撤销恢复原稿。") }
    }
    private func input(_ variable: TemplateVariable) -> Binding<String> {
        Binding(get: { inputs[variable.key] ?? variable.defaultValue.display }, set: { inputs[variable.key] = $0 })
    }
    private func apply() {
        do { application.apply(try preview.get()); onApplied() }
        catch { applyError = error.localizedDescription }
    }
}

private struct TemplateEditorSheet: View {
    @State var item: StudioTemplate
    @State private var variableForm: TemplateVariableForm
    @Bindable var library: TemplateLibraryController
    let onSaved: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var validationError: String?
    @State private var selectedTab = 0

    init(item: StudioTemplate, library: TemplateLibraryController, onSaved: @escaping (String) -> Void) {
        _item = State(initialValue: item)
        _variableForm = State(initialValue: TemplateVariableForm(variables: item.variables))
        self.library = library; self.onSaved = onSaved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑自己的模板").font(StudioTypography.serif(26))
            Text("保存在本机 · 正文用 {{变量名}} 引用变量").font(.caption).foregroundStyle(.secondary)
            HStack { TextField("模板名称", text: $item.name); Picker("模式", selection: $item.mode) { ForEach(CreationMode.allCases) { Text($0.title).tag($0) } }.frame(width: 210) }
            TextField("模板说明", text: $item.description)
            Picker("编辑内容", selection: $selectedTab) { Text("正文").tag(0); Text("变量定义").tag(1) }.pickerStyle(.segmented)
            if selectedTab == 0 {
                TextEditor(text: $item.promptPattern).font(StudioTypography.serif(16)).padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioPalette.stroke))
            } else {
                TemplateVariableFields(form: variableForm)
            }
            if let validationError { Text(validationError).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "保存中…" : "保存模板") {
                    do {
                        item.variables = try variableForm.validatedVariables()
                        try TemplateEngine.validate(item)
                        saving = true
                        Task { if await library.save(item) { onSaved(item.id) }; saving = false }
                    } catch { validationError = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(saving)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 720, height: 510)
    }
}
