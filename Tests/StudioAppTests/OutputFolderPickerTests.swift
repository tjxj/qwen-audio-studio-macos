import Foundation
import Testing
import AppKit
import StudioCore
@testable import QwenAudioStudioMacApp

@MainActor @Suite(.serialized)
struct OutputFolderPickerTests {
    @Test func reauthorizationControllerPreservesIDRejectsWrongFolderAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = root.appendingPathComponent("合成 输出")
        let wrong = root.appendingPathComponent("错误目录")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wrong, withIntermediateDirectories: false)
        let store = try StudioStore(dataRoot: root.appendingPathComponent("metadata"))
        let directories = OutputDirectoryStore(store: store, bookmarks: AppFixtureBookmarks())
        let id = try await directories.register(selectedURL: output)
        try await directories.setDefault(id)
        let original = try #require(try await store.getDirectory(id: id))
        let expired = DirectorySnapshot(id: id, version: original.version, bookmark: Data([0]), rootIdentity: original.rootIdentity)
        try await store.saveDirectory(expired)
        let rejected = OutputFolderController(directories: directories, picker: FixedFolderPicker(url: wrong))
        await rejected.loadDefault()
        #expect(await rejected.reauthorize(id) == false)
        #expect(try await store.getDirectory(id: id) == expired)
        let controller = OutputFolderController(directories: directories, picker: FixedFolderPicker(url: output))
        await controller.loadDefault()
        #expect(await controller.reauthorize(id))
        #expect(controller.defaultID == id)
        #expect(controller.defaultName == "合成 输出")
        #expect(controller.errorMessage == nil)
        let renewed = try #require(try await store.getDirectory(id: id))
        #expect(renewed.version == expired.version + 1)
        let cancelled = OutputFolderController(directories: directories, picker: FixedFolderPicker(url: nil))
        await cancelled.loadDefault()
        #expect(await cancelled.reauthorize(id) == false)
        #expect(cancelled.defaultID == id)
        #expect(try await store.getDirectory(id: id) == renewed)
        try await store.close()
        try FileManager.default.removeItem(at: root)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TEST_OPEN_PANEL"] == "1"))
    func realDialogCancelKeepsExistingSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let child = Process(); child.executableURL = repo.appendingPathComponent(".build/debug/QwenAudioStudioMacApp")
        child.arguments = ["--verify-folder-dialog-root=" + root.path]
        try child.run()
        let deadline = Date().addingTimeInterval(30)
        while child.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
        #expect(try String(contentsOf: root.appendingPathComponent("dialog-result.txt"), encoding: .utf8)
            == "native-dialog=cancelled; selection=preserved; directories=single; files=disabled")
    }
}

@MainActor private struct FixedFolderPicker: OutputFolderChoosing {
    let url: URL?
    func chooseDirectory() async -> URL? { url }
}

private struct AppFixtureBookmarks: DirectoryBookmarking {
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> BookmarkResolution {
        guard let path = String(data: data, encoding: .utf8), path.hasPrefix("/") else { throw OutputDirectoryError.reauthorizationRequired }
        return BookmarkResolution(url: URL(fileURLWithPath: path), stale: false)
    }
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
}
