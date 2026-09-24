import Foundation

public enum PromptValidationError: Error, Equatable, LocalizedError {
    case empty, tooLong, invalidBindings, missingVoice(String), invalidVoice(String)
    public var errorDescription: String? {
        switch self {
        case .empty: "请填写创作脚本。"
        case .tooLong: "编译后的 Prompt 超过 3000 个 Unicode 字符，请缩短脚本。"
        case .invalidBindings: "音色槽位必须为连续且唯一的 1–3；请补齐缺失槽位，或明确修改脚本和绑定。"
        case .missingVoice(let voice): "\(voice) 缺少对应音色，请绑定原音色或明确修改脚本。"
        case .invalidVoice(let voice): "音色标记 \(voice) 无效，仅支持 @voice1–@voice3。"
        }
    }
}

public struct CompiledPrompt: Equatable, Sendable {
    public let model: String
    public let providerMode: String
    public let text: String
    public let bindings: [ReferenceBinding]
    public var scalarCount: Int { text.unicodeScalars.count }
}

public enum PromptCompiler {
    public static func compile(mode: CreationMode, prompt: String, bindings: [ReferenceBinding]) throws -> CompiledPrompt {
        let source = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw PromptValidationError.empty }
        let ordered = bindings.sorted { $0.slot < $1.slot }
        guard ordered.count <= 3,
              ordered.enumerated().allSatisfy({ $0.element.slot == $0.offset + 1 && !$0.element.referenceID.isEmpty }),
              Set(ordered.map(\.referenceID)).count == ordered.count else { throw PromptValidationError.invalidBindings }
        let tokens = try NSRegularExpression(pattern: "@voice[0-9]*")
        for match in tokens.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let token = (source as NSString).substring(with: match.range)
            guard ["@voice1", "@voice2", "@voice3"].contains(token), let slot = Int(token.dropFirst(6)) else {
                throw PromptValidationError.invalidVoice(token)
            }
            guard ordered.contains(where: { $0.slot == slot }) else { throw PromptValidationError.missingVoice(token) }
        }
        let mapped: String
        let guidance: String
        switch mode {
        case .podcast:
            mapped = "podcast"; guidance = "创作一段自然播客，保持说话人一致、声场连续和真实对话节奏。"
        case .advertisement:
            mapped = "advertisement"; guidance = "创作一段商业广告音频，人声清晰，音效和配乐服务于信息表达。"
        case .audiobook, .drama, .game:
            mapped = "drama"; guidance = "创作一段广播剧，保持角色音色一致，按剧情顺序安排台词、环境和动作音效。"
        case .narration:
            mapped = "narration"; guidance = "创作一段以清晰人声为核心的叙事音频。"
        case .auto:
            mapped = "auto"; guidance = "根据以下要求创作完整音频。"
        }
        var text = guidance + "\n内容与台词：\n" + source
        if !ordered.isEmpty { text += "\n参考音色：按 @voice1 到 @voice\(ordered.count) 的编号使用参考音频。" }
        guard text.unicodeScalars.count <= 3000 else { throw PromptValidationError.tooLong }
        return CompiledPrompt(model: "qwen-audio-3.1-tts-next", providerMode: mapped, text: text, bindings: ordered)
    }
}
