import SwiftUI
import CoreText
import AppKit
import StudioCore

@main
struct QwenAudioStudioMacApp: App {
    @State private var preferences: StudioPreferences
    init() {
        // Captures always use isolated preferences and the synthetic, in-memory draft.
        let capture = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--capture-ui=") }
        let store: any StudioPreferenceStore = capture
            ? CapturePreferenceStore() : UserDefaultsPreferenceStore(defaults: .standard)
        _preferences = State(initialValue: StudioPreferences(store: store))
        let fontURL = Bundle.main.url(forResource: "QwenStudioSerif-Regular", withExtension: "ttf")
        if let fontURL {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
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
                .onAppear {
                    if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--capture-ui=") }) {
                        let outputPath = String(argument.dropFirst("--capture-ui=".count))
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            await Self.capturePreviews(in: URL(fileURLWithPath: outputPath), preferences: preferences)
                            for window in NSApp.windows {
                                if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
                            }
                            NSApp.terminate(nil)
                        }
                    }
                }
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
    private static func capturePreviews(in directory: URL, preferences: StudioPreferences) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview else { return }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)

        let prefix = ProcessInfo.processInfo.arguments.contains("--capture-page=templates")
            ? "templates-sample-2" : "creation"
        var checks: [String] = []
        checks.append("data=synthetic DraftController sample; isolated preferences; no network or files")
        checks.append("minimum=\(Int(window.minSize.width))x\(Int(window.minSize.height))")
        precondition(window.minSize.width >= 1120 && window.minSize.height >= 720)
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 900, height: 500)), display: true)
        try? await Task.sleep(for: .milliseconds(250))
        checks.append("undersize request=900x500; actual=\(Int(window.frame.width))x\(Int(window.frame.height))")
        precondition(window.frame.width == 1120 && window.frame.height == 720)
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
               let sheetImage = sheetView.bitmapImageRepForCachingDisplay(in: sheetView.bounds) {
                sheetView.cacheDisplay(in: sheetView.bounds, to: sheetImage)
                try? sheetImage.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name)-advanced.png"))
                checks.append("sheet=\(Int(sheet.frame.width))x\(Int(sheet.frame.height)); insideWindow=\(window.frame.contains(sheet.frame))")
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
