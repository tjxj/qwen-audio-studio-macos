import AppKit
import SwiftUI
import StudioCore

/// Bounded, opt-in native integration host. Its only mutable data lives in the
/// caller's UUID temporary fixture; it never initializes the production store.
@MainActor enum NativeOutputFolderQA {
    static func run(root: URL) -> Never {
        let canonical = root.resolvingSymlinksInPath()
        guard canonical.deletingLastPathComponent() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
              UUID(uuidString: canonical.lastPathComponent) != nil else { exit(65) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "输出目录验证 · 合成临时数据"
        window.contentView = NSHostingView(rootView: Text("原生文件夹选择与取消验证").padding(40))
        window.center(); window.makeKeyAndOrderFront(nil)
        // On a cold desktop session NSOpenPanel can spend >20 seconds loading
        // system services before the three-second delayed cancel phase begins.
        DispatchQueue.global().asyncAfter(deadline: .now() + 70) { exit(124) }
        Task { @MainActor in
            let startedAt = Date()
            func trace(_ phase: String) {
                let elapsed = String(format: "%.2f", Date().timeIntervalSince(startedAt))
                FileHandle.standardOutput.write(Data("native folder QA [\(elapsed)s]: \(phase)\n".utf8))
            }
            do {
                let output = canonical.appendingPathComponent("合成 输出", isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                let store = try StudioStore(dataRoot: canonical.appendingPathComponent("metadata"))
                let directories = OutputDirectoryStore(store: store)
                let id = try await directories.register(selectedURL: output)
                try await directories.setDefault(id)
                trace("bookmark persisted")
                let panel = NSOpenPanel()
                trace("panel initialized")
                let controller = OutputFolderController(directories: directories, picker: OutputFolderPicker(makePanel: {
                    panel.directoryURL = output
                    return panel
                }))
                await controller.loadDefault()
                trace("default loaded")
                Task { @MainActor in
                    let deadline = Date().addingTimeInterval(20)
                    while !panel.isVisible && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
                    trace("cancel; visible=\(panel.isVisible)")
                    panel.cancel(nil)
                }
                // Reproduce a slow presentation longer than the former fixed
                // 2-second cancel timer. Cancellation must wait for visibility.
                try await Task.sleep(for: .seconds(3))
                trace("begin")
                await controller.chooseDefault()
                guard controller.defaultID == id, try await directories.defaultDirectoryID() == id,
                      panel.canChooseDirectories, !panel.canChooseFiles, !panel.allowsMultipleSelection else { exit(1) }
                try await store.close()
                try Data("native-dialog=cancelled; selection=preserved; directories=single; files=disabled".utf8)
                    .write(to: canonical.appendingPathComponent("dialog-result.txt"))
                print("native folder dialog cancellation verified")
                exit(0)
            } catch { print("native folder dialog verification failed"); exit(1) }
        }
        app.run()
        exit(1)
    }
}
