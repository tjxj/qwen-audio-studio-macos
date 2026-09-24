import Foundation
import Testing
@testable import StudioCore
@testable import QwenAudioStudioMacApp

@MainActor struct ImportSheetTests {
    @Test func selectingOldFolderOnlyPreviewsUntilConfirmed() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try Data(#"{"id":"project-ui","name":"合成旧作品","mode":"podcast","prompt":"你好"}"#.utf8)
            .write(to: source.appendingPathComponent("projects/project-ui.json"))
        let store = try StudioStore(dataRoot: base.appendingPathComponent("new"))
        let flow = LegacyImportFlow(importer: LegacyImporter(dataRoot: base.appendingPathComponent("new"), store: store))
        await flow.inspect(source: source)
        #expect(flow.preview?.projects == 1)
        #expect(try await store.listProjects().isEmpty)
        await flow.confirmImport()
        #expect(flow.report?.importedProjects == 1)
        #expect(try await store.listProjects().map(\.id) == ["project-ui"])
        try await store.close()
    }
    @Test func readableReportContainsEveryIssueWithoutTruncation() {
        let report = LegacyImportReport(importedProjects: 2, importedJobs: 3, copiedAssets: 1,
                                        issues: ["缺少音频 A", "缺少音频 B", "旧音色需重选", "外部目录需授权"])
        let text = report.readableText
        #expect(text.contains("2 个项目"))
        for issue in report.issues { #expect(text.contains(issue)) }
    }

    @Test func cancellingFolderChoiceKeepsPreviousPreviewAndDoesNotImport() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-cancel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try Data(#"{"id":"project-ui","name":"合成旧作品","mode":"podcast","prompt":"你好"}"#.utf8)
            .write(to: source.appendingPathComponent("projects/project-ui.json"))
        let store = try StudioStore(dataRoot: base.appendingPathComponent("new"))
        let flow = LegacyImportFlow(importer: LegacyImporter(dataRoot: base.appendingPathComponent("new"), store: store),
                                    chooseDirectory: { nil })
        await flow.inspect(source: source)
        await flow.chooseFolder()
        #expect(flow.source == source)
        #expect(flow.preview?.projects == 1)
        #expect(try await store.listProjects().isEmpty)
        try await store.close()
    }
}
