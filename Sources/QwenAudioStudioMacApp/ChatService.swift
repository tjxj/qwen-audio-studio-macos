import Foundation
import Observation
import StudioCore

enum ChatMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

struct ParsedScript: Equatable, Sendable {
    var title: String
    var mode: CreationMode
    var script: String

    init(title: String, mode: CreationMode, script: String) {
        self.title = title
        self.mode = mode
        self.script = script
    }
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    var role: ChatMessageRole
    var content: String
    var parsedScript: ParsedScript?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        content: String,
        parsedScript: ParsedScript? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.parsedScript = parsedScript ?? ChatService.parseScript(from: content)
        self.createdAt = createdAt
    }
}

@MainActor @Observable
final class ChatService {
    var messages: [ChatMessage] = []
    var isGenerating: Bool = false
    var errorMessage: String? = nil

    static let systemPrompt = """
    你是一个专业的音频剧本编剧与提示词工程专家，精通阿里巴巴通义 Qwen Audio Next (qwen-audio-3.1-tts-next) 的音频全景声生成与剧本创作。

    【核心背景与模型能力】
    qwen-audio-3.1-tts-next 能根据文本提示词和最多 3 段参考音频，一次性端到端生成包含多角色台词、情感起伏、环境音效、背景音乐的完整音频场景。

    【剧本类型与模式】
    1. 播客 (podcast)：双人或多人对话，自然停顿，真实声场（如雨夜书房、咖啡馆、录音棚），互动感强。
    2. 广告 (advertisement)：15-30秒，节奏紧凑，开头有抓耳音效（开门、打字、倒咖啡等），背景有契合的轻盈或动感音乐，结尾淡出。
    3. 旁白 (narration)：纪录片、科技解说、短视频画外音，吐字清晰，语速均匀，录音室安静声场。
    4. 广播剧 (drama)：剧情冲突，空间混响，包含具体动作音效（脚步声、推门、关窗、杯碟碰撞），情绪表达丰富。
    5. 游戏配音 (game)：具有强烈角色特点（如沧桑酒馆老板、激昂指挥官、神秘法师），附带环境与法术/机械音效。
    6. 有声书 (audiobook)：故事感强，富有感染力的叙述者与分角色演绎。

    【创作与格式规范】
    1. 任务说明明确：明确指出时长（如 15 秒、30 秒、60 秒）和类型。
    2. 环境声场与混响：描写录音空间（如“窗外细雨，室内声场温暖沉稳”、“房间混响较短”）。
    3. 人物与台词：明确人物音色特征；若涉及参考音频，可使用 @voice1、@voice2、@voice3 标记对应角色；台词必须使用中文双引号“...”包裹，并在括号内注明语气情绪（如“（压低声音）”、“（爽朗地笑）”）。
    4. 严格字数约束：最终剧本 prompt 严禁超过 3000 字符。
    5. 输出格式要求：
    在提供你的创作解析或设计灵感后，最终必须使用以下专门代码块包裹完整剧本，确保用户可一键导入创作台：
    ```qwen-script
    [标题]: <简短精准的标题，不超过15字>
    [模式]: <播客 | 广告 | 旁白 | 广播剧 | 游戏配音 | 有声书 | 自定义>
    <这里填写完整的音频场景描述与提示词正文>
    ```
    """

    init() {}

    func clearMessages() {
        messages.removeAll()
        errorMessage = nil
    }

    nonisolated static func parseScript(from text: String) -> ParsedScript? {
        // Look for ```qwen-script ... ``` or standard ``` blocks
        let pattern = "```(?:qwen-script)?\\s*\\n?([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let blockContent = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            
            var title = "未命名灵感脚本"
            var mode: CreationMode = .podcast
            var scriptLines: [String] = []

            let lines = blockContent.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[标题]:") || trimmed.hasPrefix("[标题]：") {
                    let raw = trimmed.replacingOccurrences(of: "[标题]:", with: "")
                        .replacingOccurrences(of: "[标题]：", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if !raw.isEmpty { title = raw }
                } else if trimmed.hasPrefix("[模式]:") || trimmed.hasPrefix("[模式]：") {
                    let raw = trimmed.replacingOccurrences(of: "[模式]:", with: "")
                        .replacingOccurrences(of: "[模式]：", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if raw.contains("播客") { mode = .podcast }
                    else if raw.contains("广告") { mode = .advertisement }
                    else if raw.contains("旁白") || raw.contains("解说") { mode = .narration }
                    else if raw.contains("广播剧") { mode = .drama }
                    else if raw.contains("游戏") { mode = .game }
                    else if raw.contains("有声书") { mode = .audiobook }
                    else { mode = .auto }
                } else {
                    scriptLines.append(line)
                }
            }

            let scriptText = scriptLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !scriptText.isEmpty {
                return ParsedScript(title: title, mode: mode, script: scriptText)
            }
        }
        return nil
    }

    func send(text: String, preferences: StudioPreferences) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        errorMessage = nil
        let userMessage = ChatMessage(role: .user, content: trimmed)
        messages.append(userMessage)

        let apiKey = preferences.chatAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            errorMessage = "尚未配置 AI 脚本模型 API Key。请在「设置」中填写后再试。"
            return
        }

        var baseURL = preferences.chatAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.hasSuffix("/") {
            baseURL = String(baseURL.dropLast())
        }
        let endpointString = baseURL.hasSuffix("/chat/completions") ? baseURL : "\(baseURL)/chat/completions"
        guard let url = URL(string: endpointString) else {
            errorMessage = "无效的 API Base URL 地址：\(baseURL)"
            return
        }

        isGenerating = true
        defer { isGenerating = false }

        // Prepare request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 90

        // Build messages payload
        var apiMessages: [[String: String]] = [
            ["role": "system", "content": Self.systemPrompt]
        ]
        // Include latest conversation turns (up to 10 turns to avoid excessive context)
        let contextTurns = messages.suffix(10)
        for msg in contextTurns {
            apiMessages.append(["role": msg.role.rawValue, "content": msg.content])
        }

        let modelName = preferences.chatModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "deepseek-v4.1-flash"
            : preferences.chatModelName.trimmingCharacters(in: .whitespacesAndNewlines)

        let payload: [String: Any] = [
            "model": modelName,
            "messages": apiMessages,
            "temperature": 0.7
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                errorMessage = "服务器无响应，请检查网络。"
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let errorBody = String(data: data, encoding: .utf8) ?? "未知错误"
                errorMessage = "模型请求失败 (HTTP \(httpResponse.statusCode))：\(errorBody)"
                return
            }

            // Parse response
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let messageObj = firstChoice["message"] as? [String: Any],
               let content = messageObj["content"] as? String {
                let assistantMsg = ChatMessage(role: .assistant, content: content)
                messages.append(assistantMsg)
            } else {
                errorMessage = "模型返回的数据格式不符合预期。"
            }
        } catch {
            errorMessage = "网络连接异常：\(error.localizedDescription)"
        }
    }
}
