import Foundation
import SwiftUI
import AppKit
import Observation
import StudioCore

@MainActor @Observable final class LegacyImportFlow {
    let importer: LegacyImporter
    private(set) var source: URL?
    private(set) var externalFolder: URL?
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
    func chooseExternalFolder() async {
        guard let source else { return }
        let panel = NSOpenPanel()
        panel.title = "授权旧版音频所在文件夹"
        panel.prompt = "授权并重新预览"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await inspect(source: source, externalFolder: url)
    }
    func inspect(source: URL, externalFolder: URL? = nil) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        self.source = nil; preview = nil; report = nil; errorMessage = nil
        do {
            let counts = try await Task.detached { [importer] in try importer.preview(source: source, externalFolder: externalFolder) }.value
            self.source = source
            self.externalFolder = externalFolder
            preview = counts
        } catch { errorMessage = error.localizedDescription }
    }
    func confirmImport() async {
        guard !busy, let source, let preview else { return }
        busy = true; defer { busy = false }
        errorMessage = nil
        do {
            report = try await importer.import(source: source, preview: preview, externalFolder: externalFolder)
            self.preview = nil
        } catch { errorMessage = error.localizedDescription }
    }
    func exportReport() async {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "legacy-import-report.txt"
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do { try Data(report.readableText.utf8).write(to: url, options: .atomic) }
        catch { errorMessage = "导入报告保存失败，请检查所选目录权限。" }
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
        VStack(alignment: .leading, spacing: 11) {
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
            if flow.source != nil {
                Button("授权额外音频文件夹…") { Task { await flow.chooseExternalFolder() } }
                    .disabled(flow.busy).font(.caption)
                if let folder = flow.externalFolder { Text("已授权：\(folder.lastPathComponent)").font(.caption).foregroundStyle(.secondary) }
            }
            if let preview = flow.preview {
                VStack(alignment: .leading, spacing: 10) {
                    Text("预览：\(preview.projects) 个项目 · \(preview.jobs) 个任务 · \(preview.assets) 个资产")
                        .font(.headline)
                    if preview.issues.isEmpty { Text("未发现缺失的已登记音频。") }
                    else {
                        Text("发现 \(preview.issues.count) 项需关注：")
                        issueList(preview.issues)
                    }
                    Text("旧版输出目录的绝对路径不会转为授权；目录外音频须另行授权。导入后生成仍需配置原生输出文件夹。")
                        .foregroundStyle(.secondary)
                    if preview.lockFileAbsent {
                        Text("未找到旧版运行锁：请确认旧版应用已完全退出；导入前会再次校验源数据与音频内容。")
                            .foregroundStyle(.orange)
                    }
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
                if !report.issues.isEmpty { issueList(report.issues) }
                Button("导出完整报告…") { Task { await flow.exportReport() } }
                Text("关闭后在作品库刷新即可看到导入记录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = flow.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            Spacer(minLength: 0)
        }
        .padding(24).frame(width: 660, height: 500)
        .background(StudioPalette.background)
    }
    private func issueList(_ issues: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(issues.enumerated()), id: \.offset) { index, issue in
                    Text("\(index + 1). \(issue)").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.frame(maxHeight: 105).font(.caption).foregroundStyle(.orange)
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
