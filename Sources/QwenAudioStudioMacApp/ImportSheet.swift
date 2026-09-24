import Foundation
import SwiftUI
import AppKit
import Observation
import StudioCore

@MainActor @Observable final class LegacyImportFlow {
    let importer: LegacyImporter
    private(set) var source: URL?
    private(set) var preview: LegacyImportCounts?
    private(set) var report: LegacyImportReport?
    private(set) var busy = false
    var errorMessage: String?
    init(importer: LegacyImporter) { self.importer = importer }

    func chooseFolder() async {
        let panel = NSOpenPanel()
        panel.title = "选择旧版数据目录"
        panel.prompt = "预览此目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await inspect(source: url)
    }
    func inspect(source: URL) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        self.source = nil; preview = nil; report = nil; errorMessage = nil
        do {
            let counts = try await Task.detached { [importer] in try importer.preview(source: source) }.value
            self.source = source
            preview = counts
        } catch { errorMessage = error.localizedDescription }
    }
    func confirmImport() async {
        guard !busy, let source, let preview else { return }
        busy = true; defer { busy = false }
        errorMessage = nil
        do {
            report = try await importer.import(source: source, preview: preview)
            self.preview = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

struct ImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var flow: LegacyImportFlow
    init(state: AppState) {
        _flow = State(initialValue: LegacyImportFlow(importer: LegacyImporter(dataRoot: state.dataRoot, store: state.store)))
    }
    init(flow: LegacyImportFlow) { _flow = State(initialValue: flow) }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("导入旧版作品").font(StudioTypography.serif(25))
                Spacer()
                Button("关闭") { dismiss() }
            }
            Text("选择旧版应用的数据目录。预览和复制期间只读取旧资料；原有项目、音频与配置仍留在原处。请先退出旧版应用。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Button("选择旧版数据目录…") { Task { await flow.chooseFolder() } }
                .disabled(flow.busy)
            if let source = flow.source { Text(source.lastPathComponent).font(.caption).foregroundStyle(.secondary) }
            if let preview = flow.preview {
                VStack(alignment: .leading, spacing: 10) {
                    Text("预览：\(preview.projects) 个项目 · \(preview.jobs) 个任务 · \(preview.assets) 个资产")
                        .font(.headline)
                    if preview.issues.isEmpty { Text("未发现缺失的已登记音频。") }
                    else { Text("发现 \(preview.issues.count) 项需关注：\(preview.issues.prefix(2).joined(separator: "；"))") }
                    Text("旧版输出目录的绝对路径不会转为授权；目录外音频须另行授权。导入后生成仍需配置原生输出文件夹。")
                        .foregroundStyle(.secondary)
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    Spacer()
                    Button("确认导入 \(preview.projects) 个项目") { Task { await flow.confirmImport() } }
                        .buttonStyle(.borderedProminent).disabled(flow.busy)
                }
            }
            if let report = flow.report {
                Label("导入完成：\(report.importedProjects) 个项目、\(report.importedJobs) 个任务、\(report.copiedAssets) 个音频。", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if !report.issues.isEmpty { Text("仍有 \(report.issues.count) 项需关注：\(report.issues.prefix(2).joined(separator: "；"))").font(.caption).foregroundStyle(.orange) }
                Text("关闭后在作品库刷新即可看到导入记录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = flow.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            Spacer(minLength: 0)
        }
        .padding(24).frame(width: 620, height: 420)
        .background(StudioPalette.background)
    }
}

/// Screenshot-only host; the preview is populated from a disposable synthetic root.
struct ImportQAPresentation: View {
    @State private var showing = true
    let flow: LegacyImportFlow
    var body: some View {
        VStack { Text("设置").font(.largeTitle); Text("合成旧版作品导入验收") }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $showing) { ImportSheet(flow: flow) }
    }
}
