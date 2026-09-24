import SwiftUI
import CoreText
import AppKit
import StudioCore

@main
struct QwenAudioStudioMacApp: App {
    @State private var preferences: StudioPreferences
    @State private var outputFolders: OutputFolderController
    @State private var appState: AppState?
    init() {
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--verify-result-root=") }) {
            NativeResultQA.run(root: URL(fileURLWithPath: String(argument.dropFirst("--verify-result-root=".count)), isDirectory: true))
        }
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--verify-reference-memory-root=") }) {
            NativeReferenceMemoryQA.run(root: URL(fileURLWithPath: String(argument.dropFirst("--verify-reference-memory-root=".count)), isDirectory: true))
        }
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--verify-reference-audio-root=") }) {
            NativeReferenceAudioQA.run(root: URL(fileURLWithPath: String(argument.dropFirst("--verify-reference-audio-root=".count)), isDirectory: true))
        }
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--verify-folder-dialog-root=") }) {
            NativeOutputFolderQA.run(root: URL(fileURLWithPath: String(argument.dropFirst("--verify-folder-dialog-root=".count)), isDirectory: true))
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-templates") {
            do {
                let engine = try TemplateEngine()
                guard engine.templates.count == 42, CreationMode.allCases.allSatisfy({ mode in
                    engine.templates.filter { $0.mode == mode }.count == 6
                }) else { throw TemplateError.invalid("内置模板数量错误。") }
                for item in engine.templates { _ = try engine.preview(templateID: item.id, values: [:]) }
                print("templates=42; modes=7; eachMode=6; defaults=42/42; resourceSource=app-bundle")
                exit(0)
            } catch { print("template verification failed: \(error.localizedDescription)"); exit(1) }
        }
        // Captures always use isolated preferences and the synthetic, in-memory draft.
        let capture = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--capture-ui=") }
        let state = capture ? nil : try? AppState.live()
        _appState = State(initialValue: state)
        let folders = state?.outputFolders ?? OutputFolderController(directories: nil)
        _outputFolders = State(initialValue: folders)
        let store: any StudioPreferenceStore = capture
            ? CapturePreferenceStore() : UserDefaultsPreferenceStore(defaults: .standard)
        let initialPreferences = StudioPreferences(store: store)
        _preferences = State(initialValue: initialPreferences)
        state?.candidateCount = initialPreferences.defaultCandidates
        let fontURL = Bundle.main.url(forResource: "QwenStudioSerif-Regular", withExtension: "ttf")
        if let fontURL {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }
        if ProcessInfo.processInfo.arguments.contains("--capture-native-window"),
           let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--capture-ui=") }) {
            Self.runCaptureWindow(in: URL(fileURLWithPath: String(argument.dropFirst("--capture-ui=".count))), preferences: initialPreferences)
        }
    }

    var body: some Scene {
        WindowGroup("Qwen Audio Studio") {
            Group {
                if let appState { AppShell(appState: appState) }
                else {
                    ContentUnavailableView("本地作品库无法打开", systemImage: "externaldrive.badge.exclamationmark",
                        description: Text("请关闭重复运行的应用实例，检查磁盘空间与本地目录权限后重新打开。为保护草稿，当前不会启动临时内存工作区。"))
                }
            }
                .environment(preferences)
                .environment(outputFolders)
                .task {
                    AudioPlaybackController.shared.startMonitoringRoute()
                    if let appState { await appState.restore() }
                    while !Task.isCancelled {
                        _ = try? await outputFolders.referenceAudio?.cleanup()
                        try? await Task.sleep(for: .seconds(300))
                    }
                }
                .preferredColorScheme(preferences.appearance.colorScheme)
                .frame(minWidth: CGFloat(StudioLayout.minWidth),
                       minHeight: CGFloat(StudioLayout.minHeight - 52))
                .background(WindowSizing())
        }
        .defaultSize(width: 1400, height: 808)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            DraftCommands()
        }

        Settings {
            SettingsScreen(state: appState)
                .environment(preferences)
                .environment(outputFolders)
                .preferredColorScheme(preferences.appearance.colorScheme)
        }
    }

    @MainActor
    private static func runCaptureWindow(in directory: URL, preferences: StudioPreferences) -> Never {
        // Deterministic native hosting avoids restoring a previously closed SwiftUI scene.
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 808),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Qwen Audio Studio"
        window.minSize = NSSize(width: StudioLayout.minWidth, height: StudioLayout.minHeight)
        window.contentView = NSHostingView(rootView: AppShell(qaMode: true).environment(preferences)
            .environment(OutputFolderController(directories: nil))
            .preferredColorScheme(preferences.appearance.colorScheme))
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { exit(124) }
        Task { @MainActor in
            if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--capture-task9-root=") }) {
                do {
                    let root = URL(fileURLWithPath: String(argument.dropFirst("--capture-task9-root=".count)), isDirectory: true)
                    let state = try AppState(dataRoot: root)
                    try await seedCapture(state: state, root: root)
                    let settingsCapture = ProcessInfo.processInfo.arguments.contains("--capture-page=settings")
                    let content: AnyView = settingsCapture
                        ? AnyView(SettingsScreen(state: state, qaMode: true).environment(preferences).environment(state.outputFolders))
                        : AnyView(AppShell(appState: state, qaMode: true).environment(preferences).environment(state.outputFolders))
                    window.contentView = NSHostingView(rootView: content.preferredColorScheme(preferences.appearance.colorScheme))
                    if settingsCapture { window.toolbar = nil; window.title = "设置" }
                } catch { print("capture fixture setup failed: \(error.localizedDescription)"); exit(1) }
            }
            try? await Task.sleep(for: .seconds(2))
            await capturePreviews(in: directory, preferences: preferences)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            guard files.filter({ $0.hasSuffix(".png") }).count >= 4 else { print("capture failed: incomplete native window images"); exit(1) }
            print("capture complete: native AppShell, isolated synthetic stores, 2x images")
            exit(0)
        }
        app.run()
        exit(1)
    }

    @MainActor private static func seedCapture(state: AppState, root: URL) async throws {
        let output = root.appendingPathComponent("Synthetic Output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let directoryID = try await state.directories.register(selectedURL: output)
        try await state.directories.setDefault(directoryID)
        await state.outputFolders.loadDefault()
        let examples: [(CreationMode, String, String)] = [
            (.podcast, "雨夜电台片头", "【对白：讲述者】把疲惫留在门外，今晚只听一段温柔的声音。"),
            (.advertisement, "清晨咖啡短广告", "【对白：店员】一杯刚好醒来的咖啡，从今天的第一缕香气开始。"),
            (.audiobook, "古城旅行有声书", "【旁白】午后，古城的石板路上响起轻快的脚步声。"),
            (.drama, "电话那端的重逢", "【对白：甲】你终于接电话了。"),
            (.game, "产品演示配音", "【对白：解说】从这里开始，完成一次简单的体验。"),
            (.narration, "城市影像旁白", "【旁白】日落之后，街灯依次亮起。"),
            (.podcast, "慢生活晚安语", "【对白：讲述者】把今晚的时间，留给自己。")
        ]
        for (index, example) in examples.enumerated() {
            let fields = DraftFields(name: example.1, mode: example.0, prompt: example.2, outputDirectoryID: directoryID)
            let project = try await state.store.createProject(fields: fields)
            if index == 0 { state.draft.load(project); try await state.store.setCurrentProject(id: project.id) }
            let compiled = try PromptCompiler.compile(mode: example.0, prompt: example.2, bindings: [])
            guard let directory = try await state.store.getDirectory(id: directoryID) else { continue }
            let requestID = "synthetic-\(index)"
            let batch = try await state.store.createBatch(BatchSubmission(clientRequestID: requestID, project: project,
                compiledPrompt: compiled.text, candidateSeeds: [100 + index], directory: directory, references: [],
                consent: UploadConsent(clientRequestID: requestID, references: [], confirmed: true)))
            let id = batch.jobIDs[0]
            if index < 3 {
                _ = try await state.store.claimJob(id: id)
                _ = try await state.store.transitionJob(id: id, from: .preparing, to: .requesting)
                _ = try await state.store.recordProviderResponse(id: id, response: ProviderResponseSnapshot(
                    providerRequestID: "synthetic\(index)", audioURL: URL(string: "https://example.invalid/synthetic.wav")!))
                _ = try await state.store.transitionJob(id: id, from: .downloading, to: .validating)
                _ = try await state.store.transitionJob(id: id, from: .validating, to: .success)
                let lease = try await state.directories.resolveForJob(id, directoryID: directoryID)
                _ = try await state.assets.write(data: syntheticTone(), fileName: "audio.wav", kind: "audio", job: id, lease: lease)
                lease.close()
            } else if index == 3 { _ = try await state.store.cancelQueued(id: id) }
            if index == 0 { try await state.store.updateJobMetadata(id: id, name: "晚安版", favorite: true, note: "合成验收示例") }
        }
        await state.templates.reload()
    }

    private static func syntheticTone() -> Data {
        let rate = 24_000
        let frames = rate * 3
        var data = Data()
        func u16(_ value: UInt16) { var copy = value.littleEndian; withUnsafeBytes(of: &copy) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var copy = value.littleEndian; withUnsafeBytes(of: &copy) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + frames * 2)); data.append(contentsOf: "WAVEfmt ".utf8)
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(frames * 2))
        for index in 0..<frames {
            let sample = Int16(7000 * sin(2 * Double.pi * 220 * Double(index) / Double(rate)))
            u16(UInt16(bitPattern: sample))
        }
        return data
    }

    @MainActor
    private static func capturePreviews(in directory: URL, preferences: StudioPreferences) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview else { return }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)

        let prefix = ProcessInfo.processInfo.arguments.contains("--capture-page=templates") ? "templates" :
            ProcessInfo.processInfo.arguments.contains("--capture-page=library") ? "library" :
            ProcessInfo.processInfo.arguments.contains("--capture-page=settings") ? "settings" : "creation"
        if prefix == "settings" { window.toolbar = nil; window.title = "设置" }
        var checks: [String] = []
        checks.append("data=public templates and synthetic draft; CapturePreferenceStore; temporary isolated root when --capture-task9-root is supplied; no network or user files")
        checks.append("hosting=private NSWindow + NSHostingView(AppShell); window minimum resize behavior not re-tested by this harness")
        if let engine = try? TemplateEngine() { checks.append("bundledTemplates=\(engine.templates.count)") }
        checks.append("minimum=\(Int(window.minSize.width))x\(Int(window.minSize.height))")
        for (width, name, appearance) in [
            (1280, "\(prefix)-light-1280", NSAppearance.Name.aqua),
            (1280, "\(prefix)-dark-1280", NSAppearance.Name.darkAqua),
            (1120, "\(prefix)-light-1120", NSAppearance.Name.aqua),
            (1120, "\(prefix)-dark-1120", NSAppearance.Name.darkAqua),
        ] {
            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: width, height: 720)), display: true)
            preferences.appearance = appearance == .aqua ? .light : .dark
            NSApp.appearance = NSAppearance(named: appearance)
            window.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(for: .milliseconds(250))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            view.displayIfNeeded()
            let bounds = view.bounds
            guard let image = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            image.size = bounds.size
            view.cacheDisplay(in: bounds, to: image)
            guard let data = image.representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: directory.appendingPathComponent("\(name).png"))
            checks.append("\(name): frame=\(Int(window.frame.width))x\(Int(window.frame.height)); pixels=\(image.pixelsWide)x\(image.pixelsHigh)")
            if let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview,
               let sheetImage = NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: Int(sheetView.bounds.width * 2), pixelsHigh: Int(sheetView.bounds.height * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                sheetImage.size = sheetView.bounds.size
                sheetView.cacheDisplay(in: sheetView.bounds, to: sheetImage)
                try? sheetImage.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name)-sheet.png"))
                checks.append("sheet=\(Int(sheet.frame.width))x\(Int(sheet.frame.height)); pixels=\(sheetImage.pixelsWide)x\(sheetImage.pixelsHigh); insideWindow=\(window.frame.contains(sheet.frame))")
            }
        }
        try? checks.joined(separator: "\n").write(to: directory.appendingPathComponent("\(prefix)-window-checks.txt"), atomically: true, encoding: .utf8)
    }
}

private struct DraftControllerFocusKey: FocusedValueKey { typealias Value = DraftController }
extension FocusedValues {
    var draftController: DraftController? {
        get { self[DraftControllerFocusKey.self] }
        set { self[DraftControllerFocusKey.self] = newValue }
    }
}

private struct DraftCommands: Commands {
    @FocusedValue(\.draftController) private var draft
    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("保存草稿") { Task { try? await draft?.saveNow() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(draft == nil || draft?.state == .conflict)
        }
    }
}

private struct CapturePreferenceStore: StudioPreferenceStore {
    func string(for key: String) -> String? { nil }
    func set(_ value: String, for key: String) {}
}

private struct WindowSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> SizingView { SizingView() }
    func updateNSView(_ nsView: SizingView, context: Context) {}
    final class SizingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.minSize = NSSize(width: StudioLayout.minWidth, height: StudioLayout.minHeight)
        }
    }
}
