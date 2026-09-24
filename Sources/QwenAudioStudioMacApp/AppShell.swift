import SwiftUI

enum StudioPalette {
    static let green = Color(red: 0.10, green: 0.38, blue: 0.33)
    static let greenSoft = Color(red: 0.89, green: 0.95, blue: 0.93)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let stroke = Color(nsColor: .separatorColor).opacity(0.65)
    static let muted = Color.secondary
}

enum StudioTypography {
    static func serif(_ size: CGFloat) -> Font {
        .custom("QwenStudioSerif-Regular", size: size)
    }
}

private enum StudioPage: String, CaseIterable, Identifiable {
    case creation = "创作台"
    case library = "作品库"
    case templates = "灵感模板"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .creation: "waveform"
        case .library: "square.stack"
        case .templates: "lightbulb"
        }
    }
}

struct AppShell: View {
    @State private var selection: StudioPage? = ProcessInfo.processInfo.arguments.contains("--capture-page=templates") ? .templates : .creation
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                brand
                    .padding(.horizontal, 18)
                    .padding(.top, 26)
                    .padding(.bottom, 27)

                VStack(spacing: 5) {
                    ForEach(StudioPage.allCases) { page in
                        Button {
                            selection = page
                        } label: {
                            Label(page.rawValue, systemImage: page.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(selection == page
                                                 ? (colorScheme == .dark
                                                    ? Color(red: 0.54, green: 0.78, blue: 0.69)
                                                    : StudioPalette.green)
                                                 : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 13)
                                .frame(height: 42)
                                .background(selection == page ? StudioPalette.green.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == page ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal, 11)

                Spacer(minLength: 8)

                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        openSettings()
                    } label: {
                        Label("设置", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(10)

                    Text("让灵感，被听见。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                }
                .padding(.horizontal, 13)
                .padding(.bottom, 18)
            }
            .frame(minWidth: 196, idealWidth: 204, maxWidth: 220)
            .background(StudioPalette.surface)
        } detail: {
            Group {
                switch selection ?? .creation {
                case .creation: CreationScreen()
                case .library: LibraryScreen()
                case .templates: TemplateScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(StudioPalette.green)
    }

    private var brand: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(StudioPalette.green)
                .frame(width: 27)

            VStack(alignment: .leading, spacing: 0) {
                Text("Qwen Audio")
                Text("Studio")
            }
            .font(StudioTypography.serif(16))
            .foregroundStyle(.primary)
            .lineSpacing(-2)
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
