import SwiftUI
import StudioCore

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
    let appState: AppState?
    @State private var draft: DraftController
    @State private var templateApplication: TemplateApplicationController
    @State private var templateLibrary = TemplateLibraryController()
    @State private var promptEditor = PromptEditorHandle()
    @State private var selection: StudioPage? = ProcessInfo.processInfo.arguments.contains("--capture-page=templates") ? .templates :
        ProcessInfo.processInfo.arguments.contains("--capture-page=library") ? .library : .creation
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme

    init(appState: AppState? = nil, qaMode: Bool = false) {
        self.appState = appState
        let longScript = ProcessInfo.processInfo.arguments.contains("--capture-long-script")
        let fields: DraftFields? = longScript ? DraftFields(name: "长脚本布局验证", prompt:
            Array(repeating: DraftController.sample(for: .podcast), count: 20).joined(separator: "\n\n")) :
            (qaMode ? DraftFields(name: "雨夜里的慢生活", prompt: DraftController.sample(for: .podcast)) : nil)
        // QA uses these in-memory adapters explicitly; never inject production persistence here.
        let controller = appState?.draft ?? DraftController(fields: fields, store: InMemoryDraftStore())
        _draft = State(initialValue: controller)
        _templateApplication = State(initialValue: TemplateApplicationController(draft: controller))
        if let appState { _templateLibrary = State(initialValue: appState.templates) }
    }

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
                case .creation: CreationScreen(draft: draft, sharedUndoManager: templateApplication.undoManager, editor: promptEditor, appState: appState)
                case .library: LibraryScreen(state: appState) { project in
                    Task { await appState?.openProjectID(project.id); selection = .creation }
                }
                case .templates: TemplateScreen(library: templateLibrary, application: templateApplication) { selection = .creation }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(colorScheme == .dark ? Color(red: 0.50, green: 0.79, blue: 0.69) : StudioPalette.green)
        .focusedSceneValue(\.draftController, draft)
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
