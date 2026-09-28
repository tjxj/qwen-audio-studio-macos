import SwiftUI
import StudioCore

enum StudioPalette {
    static let green = Color(red: 0.02, green: 0.59, blue: 0.41)
    static let greenSoft = Color(red: 0.92, green: 0.98, blue: 0.95)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let stroke = Color(nsColor: .separatorColor).opacity(0.45)
    static let muted = Color.secondary
}

enum StudioTypography {
    static func serif(_ size: CGFloat) -> Font {
        .custom("QwenStudioSerif-Regular", size: size)
    }
}

struct AppShell: View {
    let appState: AppState?
    @State private var draft: DraftController
    @State private var templateApplication: TemplateApplicationController
    @State private var templateLibrary = TemplateLibraryController()
    @State private var promptEditor = PromptEditorHandle()
    @State private var localSelection: StudioPage = ProcessInfo.processInfo.arguments.contains("--capture-page=chat") ? .chat :
        (ProcessInfo.processInfo.arguments.contains("--capture-page=templates") ? .templates :
        (ProcessInfo.processInfo.arguments.contains("--capture-page=library") ? .library : .creation))
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme

    private var currentSelection: StudioPage {
        get { appState?.selectedPage ?? localSelection }
        nonmutating set {
            if let appState {
                appState.selectedPage = newValue
            } else {
                localSelection = newValue
            }
        }
    }

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
                    .padding(.top, 24)
                    .padding(.bottom, 22)

                VStack(spacing: 5) {
                    ForEach(StudioPage.allCases) { page in
                        Button {
                            currentSelection = page
                        } label: {
                            Label(page.rawValue, systemImage: page.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(currentSelection == page
                                                 ? (colorScheme == .dark
                                                    ? Color(red: 0.54, green: 0.78, blue: 0.69)
                                                    : StudioPalette.green)
                                                 : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 13)
                                .frame(height: 40)
                                .background(currentSelection == page ? StudioPalette.green.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(currentSelection == page ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal, 11)

                Spacer(minLength: 8)

                Button {
                    openSettings()
                } label: {
                    Label("偏好设置", systemImage: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 13)
                        .frame(height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 11)
                .padding(.bottom, 16)
            }
            .frame(minWidth: 196, idealWidth: 204, maxWidth: 220)
            .background(StudioPalette.surface)
        } detail: {
            Group {
                switch currentSelection {
                case .chat:
                    ChatScreen(
                        onImportToCreation: { title, mode, scriptText in
                            draft.change { fields in
                                fields.name = title
                                fields.mode = mode
                                fields.prompt = scriptText
                            }
                            currentSelection = .creation
                        },
                        onOpenSettings: {
                            openSettings()
                        }
                    )
                case .creation:
                    CreationScreen(draft: draft, sharedUndoManager: templateApplication.undoManager, editor: promptEditor, appState: appState)
                case .library:
                    LibraryScreen(state: appState) { project in
                        Task { await appState?.openProjectID(project.id); currentSelection = .creation }
                    }
                case .templates:
                    TemplateScreen(library: templateLibrary, application: templateApplication) { currentSelection = .creation }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(colorScheme == .dark ? Color(red: 0.50, green: 0.79, blue: 0.69) : StudioPalette.green)
        .focusedSceneValue(\.draftController, draft)
    }

    private var brand: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(StudioPalette.green.gradient)
                    .frame(width: 32, height: 32)
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Qwen Audio")
                        .font(.system(size: 13, weight: .bold))
                    Text("Studio")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text("让灵感，被听见")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
