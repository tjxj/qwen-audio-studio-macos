import Foundation
import Testing
import AppKit
import StudioCore
@testable import QwenAudioStudioMacApp

@MainActor @Suite(.serialized)
struct OutputFolderPickerTests {
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
