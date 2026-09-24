import AppKit
import SwiftUI
import StudioCore

/// Isolated UI integration probe. The dialog is a real NSOpenPanel; the selected
/// data and native target live only in a caller-owned UUID temporary directory.
@MainActor enum NativeImportDialogQA {
    static func run(root: URL) -> Never {
        let canonical = root.resolvingSymlinksInPath()
        guard canonical.deletingLastPathComponent() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
              UUID(uuidString: canonical.lastPathComponent) != nil else { exit(65) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "旧版导入对话框 · 合成临时数据"
        window.contentView = NSHostingView(rootView: Text("原生旧版数据目录选择验证").padding(40))
        window.center(); window.makeKeyAndOrderFront(nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 70) { exit(124) }
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: false)
                let source = canonical.appendingPathComponent("Synthetic Legacy", isDirectory: true)
                try FileManager.default.createDirectory(at: source.appendingPathComponent("projects"), withIntermediateDirectories: true)
                try Data(#"{"id":"synthetic-project","name":"合成旧作品","mode":"podcast","prompt":"合成文本"}"#.utf8)
                    .write(to: source.appendingPathComponent("projects/synthetic-project.json"))
                let target = canonical.appendingPathComponent("native", isDirectory: true)
                let store = try StudioStore(dataRoot: target)
                let panel = NSOpenPanel()
                panel.title = "选择旧版数据目录"
                panel.prompt = "预览此目录"
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.directoryURL = source
                let flow = LegacyImportFlow(importer: LegacyImporter(dataRoot: target, store: store), chooseDirectory: {
                    panel.runModal() == .OK ? panel.url : nil
                })
                await flow.inspect(source: source)
                guard flow.preview?.projects == 1 else { exit(1) }
                var visible = false
                print("native import QA: preview ready, presenting panel"); fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    visible = panel.isVisible
                    print("native import QA: cancelling; visible=\(visible)"); fflush(stdout)
                    panel.cancel(nil)
                }
                await flow.chooseFolder()
                print("native import QA: returned from panel"); fflush(stdout)
                guard visible, flow.source == source, flow.preview?.projects == 1,
                      try await store.listProjects().isEmpty else { exit(1) }
                try "nativeDialog=visible-and-cancelled; source=synthetic; preview=1; imported=0; selection=preserved\n".write(
                    to: canonical.appendingPathComponent("import-dialog-result.txt"), atomically: true, encoding: .utf8)
                try await store.close()
                print("native import dialog cancellation verified; preview preserved; no import")
                exit(0)
            } catch { print("native import dialog QA failed: \(error.localizedDescription)"); exit(1) }
        }
        app.run()
        exit(1)
    }
}
