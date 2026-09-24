import SwiftUI
import CoreText
import AppKit
import StudioCore

@main
struct QwenAudioStudioMacApp: App {
    init() {
        let fontURL = Bundle.main.url(forResource: "QwenStudioSerif-Regular", withExtension: "ttf")
        if let fontURL {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }
    }

    var body: some Scene {
        WindowGroup("Qwen Audio Studio") {
            AppShell()
                .frame(minWidth: CGFloat(StudioLayout.minWidth),
                       minHeight: CGFloat(StudioLayout.minHeight - 52))
                .onAppear {
                    if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--capture-ui=") }) {
                        let outputPath = String(argument.dropFirst("--capture-ui=".count))
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            Self.capturePreviews(in: URL(fileURLWithPath: outputPath))
                            NSApp.terminate(nil)
                        }
                    }
                }
        }
        .defaultSize(width: 1400, height: 808)
        .commands {
            SidebarCommands()
        }

        Settings {
            SettingsScreen()
        }
    }

    @MainActor
    private static func capturePreviews(in directory: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView else { return }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        window.setContentSize(NSSize(width: 1280, height: 668))
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)

        for (name, appearance) in [
            ("creation-light-1280", NSAppearance.Name.aqua),
            ("creation-dark-1280", NSAppearance.Name.darkAqua),
        ] {
            window.appearance = NSAppearance(named: appearance)
            window.displayIfNeeded()
            view.displayIfNeeded()
            let bounds = view.bounds
            guard let image = view.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            view.cacheDisplay(in: bounds, to: image)
            guard let data = image.representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }
}
