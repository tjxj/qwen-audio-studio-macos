import SwiftUI
import CoreText
import AppKit
import StudioCore

@main
struct QwenAudioStudioMacApp: App {
    @State private var preferences: StudioPreferences
    init() {
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
        let store: any StudioPreferenceStore = capture
            ? CapturePreferenceStore() : UserDefaultsPreferenceStore(defaults: .standard)
        let initialPreferences = StudioPreferences(store: store)
        _preferences = State(initialValue: initialPreferences)
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
            AppShell()
                .environment(preferences)
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
            SettingsScreen()
                .environment(preferences)
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
            .preferredColorScheme(preferences.appearance.colorScheme))
        window.center()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { exit(124) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            await capturePreviews(in: directory, preferences: preferences)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            guard files.filter({ $0.hasSuffix(".png") }).count >= 4 else { print("capture failed: incomplete native window images"); exit(1) }
            print("capture complete: native AppShell, isolated stores, 2x images")
            exit(0)
        }
        app.run()
        exit(1)
    }

    @MainActor
    private static func capturePreviews(in directory: URL, preferences: StudioPreferences) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview else { return }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)

        let prefix = ProcessInfo.processInfo.arguments.contains("--capture-page=templates")
            ? "templates" : "creation"
        var checks: [String] = []
        checks.append("data=public templates and synthetic draft; InMemoryDraftStore; InMemoryTemplateStore; CapturePreferenceStore; no network or user files")
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
        try? checks.joined(separator: "\n").write(to: directory.appendingPathComponent("window-checks.txt"), atomically: true, encoding: .utf8)
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
