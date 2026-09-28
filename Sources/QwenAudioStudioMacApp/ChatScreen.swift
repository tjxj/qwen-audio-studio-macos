import SwiftUI
import AppKit
import StudioCore

struct ChatScreen: View {
    @Environment(StudioPreferences.self) private var preferences
    @Environment(\.colorScheme) private var colorScheme

    var onImportToCreation: (String, CreationMode, String) -> Void
    var onOpenSettings: () -> Void

    @State private var service = ChatService()
    @State private var inputText: String = ""
    @State private var copiedScriptID: UUID? = nil

    private struct SuggestionItem: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let mode: String
        let prompt: String
    }

    private let suggestions: [SuggestionItem] = [
        SuggestionItem(
            icon: "antenna.radiowaves.left.and.right",
            title: "双人科技播客",
            mode: "播客",
            prompt: "创作一段雨夜书房双人播客。窗外持续轻雨，室内声场温暖沉稳。主持人使用沉稳男声，嘉宾使用明亮女声，讨论 AI 创作变迁，结尾雨声轻微渐弱。"
        ),
        SuggestionItem(
            icon: "megaphone",
            title: "15秒产品广告",
            mode: "广告",
            prompt: "创作一段 15 秒新灵感咖啡的产品广告。开头是一声清脆的开门风铃声，明亮女声说出广告词，下方有轻盈电子音乐，结尾音乐淡出。"
        ),
        SuggestionItem(
            icon: "bubble.left.and.bubble.right",
            title: "悬疑广播剧",
            mode: "广播剧",
            prompt: "创作一段悬疑广播剧。侦探与店主对话，门外脚步声由远及近，木门打开。@voice1 扮演侦探压低声音质问，@voice2 扮演店主紧张回答，带有短混响。"
        ),
        SuggestionItem(
            icon: "gamecontroller",
            title: "奇幻酒馆配音",
            mode: "游戏配音",
            prompt: "创作一段 20 秒奇幻 RPG 游戏酒馆老店主的台词。背景有壁炉柴火噼啪声和嘈杂谈话声，老店主声音沧桑沙哑，向冒险者低语交代古老任务。"
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            topBar

            Divider().opacity(0.4)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        if service.messages.isEmpty {
                            emptyWelcomeView
                        } else {
                            ForEach(service.messages) { message in
                                messageRow(message)
                                    .id(message.id)
                            }
                        }

                        if service.isGenerating {
                            generatingIndicator
                                .id("generating_indicator")
                        }

                        if let error = service.errorMessage {
                            errorMessageView(error)
                        }
                    }
                    .frame(maxWidth: 820)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: service.messages.count) { _, _ in
                    if let last = service.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: service.isGenerating) { _, isGen in
                    if isGen {
                        withAnimation { proxy.scrollTo("generating_indicator", anchor: .bottom) }
                    }
                }
            }

            inputSection
        }
        .background(
            colorScheme == .dark
                ? StudioPalette.background
                : Color(nsColor: .windowBackgroundColor)
        )
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 8) {
                Text("AI 编剧")
                    .font(.system(size: 15, weight: .bold))

                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioPalette.green)
                    Text("Qwen Audio Next 剧本引擎")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(StudioPalette.green.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(StudioPalette.green.opacity(0.2), lineWidth: 0.8))
            }

            Spacer()

            HStack(spacing: 12) {
                // Model indicator button
                Button {
                    onOpenSettings()
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(preferences.chatAPIKey.isEmpty ? Color.orange : StudioPalette.green)
                            .frame(width: 7, height: 7)
                        Text(preferences.chatModelName.isEmpty ? "deepseek-v4.1-flash" : preferences.chatModelName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Image(systemName: "gearshape")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioPalette.stroke))
                }
                .buttonStyle(.plain)
                .help("点击前往偏好设置修改模型与 API Key")

                if !service.messages.isEmpty {
                    Button {
                        withAnimation { service.clearMessages() }
                    } label: {
                        Label("清空对话", systemImage: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 44)
        .background(StudioPalette.surface)
    }

    private var emptyWelcomeView: some View {
        VStack(spacing: 26) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(StudioPalette.green.opacity(0.12))
                        .frame(width: 60, height: 60)
                    Image(systemName: "sparkles")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(StudioPalette.green)
                }
                .padding(.bottom, 4)

                Text("创作高质量的全景声剧本")
                    .font(.system(size: 20, weight: .bold))

                Text("内置 Qwen Audio Next 剧本创作知识库。直接描述你的创意场景，AI 将为你生成包含角色台词、情绪表达、环境声与混响标记的完整剧本。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 560)
            }
            .padding(.top, 28)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("灵感预设 · 点击即发")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(suggestions) { item in
                        Button {
                            inputText = item.prompt
                            sendMessage()
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(item.title, systemImage: item.icon)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(item.mode)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(StudioPalette.green)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(StudioPalette.green.opacity(0.12), in: Capsule())
                                }

                                Text(item.prompt)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioPalette.stroke))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 16)
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .user {
                Spacer(minLength: 40)
                Text(message.content)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        colorScheme == .dark
                            ? StudioPalette.green.opacity(0.24)
                            : StudioPalette.green.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(StudioPalette.green.opacity(0.35), lineWidth: 1)
                    )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(StudioPalette.green.opacity(0.15))
                                .frame(width: 22, height: 22)
                            Image(systemName: "sparkles")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(StudioPalette.green)
                        }

                        Text("AI 编剧")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(StudioPalette.green)

                        Spacer()
                    }

                    // Raw text commentary
                    let cleanText = cleanCommentary(from: message.content)
                    if !cleanText.isEmpty {
                        Text(cleanText)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }

                    // Parsed script card
                    if let script = message.parsedScript {
                        scriptCard(messageID: message.id, script: script)
                    }
                }
                .padding(16)
                .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioPalette.stroke))
                Spacer(minLength: 40)
            }
        }
    }

    private func cleanCommentary(from content: String) -> String {
        let pattern = "```(?:qwen-script)?[\\s\\S]*?```"
        let stripped = content.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped
    }

    private func scriptCard(messageID: UUID, script: ParsedScript) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text(script.title)
                    .font(.system(size: 14, weight: .bold))

                Text(script.mode.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioPalette.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(StudioPalette.green.opacity(0.12), in: Capsule())

                Spacer()

                Text("\(script.script.count) 字")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Script body with editorial serif
            Text(script.script)
                .font(preferences.scriptFont.swiftUIFont(size: CGFloat(preferences.scriptSize)))
                .lineSpacing(5)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioPalette.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioPalette.stroke))
                .textSelection(.enabled)

            // Actions
            HStack(spacing: 12) {
                Button {
                    onImportToCreation(script.title, script.mode, script.script)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("一键进入创作台微调")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(StudioPalette.green, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Button {
                    copyToClipboard(script.script)
                    copiedScriptID = messageID
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if copiedScriptID == messageID { copiedScriptID = nil }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copiedScriptID == messageID ? "checkmark" : "doc.on.doc")
                        Text(copiedScriptID == messageID ? "已复制" : "复制脚本")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioPalette.stroke))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(
            colorScheme == .dark
                ? Color.white.opacity(0.04)
                : Color.black.opacity(0.02),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(StudioPalette.green.opacity(0.35), lineWidth: 1)
        )
    }

    private var generatingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("AI 编剧正在构思全景声剧本…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func errorMessageView(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            Spacer()
            if preferences.chatAPIKey.isEmpty {
                Button("去设置") {
                    onOpenSettings()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StudioPalette.green)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.3)))
    }

    // Modern floating input box
    private var inputSection: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                // Key Missing Banner
                if preferences.chatAPIKey.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                        Text("尚未配置 AI 模型 API Key（默认 deepseek-v4.1-flash）")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            onOpenSettings()
                        } label: {
                            HStack(spacing: 4) {
                                Text("立即配置")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10))
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StudioPalette.green)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.25), lineWidth: 1))
                }

                // Main Floating Input Card
                VStack(spacing: 0) {
                    // Multi-line editor area
                    ZStack(alignment: .topLeading) {
                        if inputText.isEmpty {
                            Text("描述你想创作的音频场景、人物关系、对白或具体修改要求（如：写一段30秒咖啡广告，带开门风铃声）…")
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 16)
                                .padding(.top, 14)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $inputText)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 6)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 80, maxHeight: 180)
                    }

                    Divider().opacity(0.35)

                    // Bottom Toolbar inside Input Card
                    HStack(alignment: .center, spacing: 8) {
                        // Quick mode prompt chips
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                quickChip("🎙️ 双人播客", promptPrefix: "创作一段双人播客：")
                                quickChip("📢 15s广告", promptPrefix: "创作一段 15 秒产品广告：")
                                quickChip("📻 广播剧", promptPrefix: "创作一段戏剧冲突强烈的广播剧：")
                                quickChip("🎙️ 旁白解说", promptPrefix: "创作一段沉稳的科技旁白解说：")
                                quickChip("🎮 游戏台词", promptPrefix: "创作一段奇幻游戏 NPC 台词：")
                            }
                            .padding(.vertical, 3)
                        }

                        Spacer(minLength: 8)

                        // Word count & shortcut hint
                        HStack(spacing: 10) {
                            if !inputText.isEmpty {
                                Text("\(inputText.count) 字")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }

                            Text("⌘ ⏎ 发送")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))

                            // Send Button
                            Button {
                                sendMessage()
                            } label: {
                                HStack(spacing: 5) {
                                    if service.isGenerating {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "arrow.up")
                                            .font(.system(size: 12, weight: .bold))
                                    }
                                    Text(service.isGenerating ? "构思中" : "发送")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .frame(height: 30)
                                .background(
                                    inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.isGenerating
                                        ? Color.secondary.opacity(0.3)
                                        : StudioPalette.green,
                                    in: Capsule()
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.isGenerating)
                            .keyboardShortcut(.return, modifiers: [.command])
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        colorScheme == .dark
                            ? Color.white.opacity(0.02)
                            : Color.black.opacity(0.015)
                    )
                }
                .background(
                    colorScheme == .dark
                        ? StudioPalette.surface
                        : Color.white,
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            colorScheme == .dark
                                ? StudioPalette.stroke
                                : Color.black.opacity(0.12),
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: colorScheme == .dark
                        ? Color.black.opacity(0.35)
                        : Color.black.opacity(0.06),
                    radius: 12,
                    x: 0,
                    y: 4
                )
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
    }

    private func quickChip(_ title: String, promptPrefix: String) -> some View {
        Button {
            if inputText.isEmpty {
                inputText = promptPrefix
            } else {
                inputText += " " + promptPrefix
            }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    colorScheme == .dark
                        ? Color.white.opacity(0.06)
                        : Color.black.opacity(0.04),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .stroke(StudioPalette.stroke, lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
    }

    private func sendMessage() {
        let text = inputText
        inputText = ""
        Task {
            await service.send(text: text, preferences: preferences)
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
