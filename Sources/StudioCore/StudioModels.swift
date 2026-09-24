public enum CreationMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case podcast
    case advertisement
    case audiobook
    case drama
    case game
    case narration
    case auto

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .podcast: "播客"
        case .advertisement: "广告"
        case .audiobook: "有声书"
        case .drama: "广播剧"
        case .game: "游戏配音"
        case .narration: "旁白"
        case .auto: "自定义"
        }
    }

    public var symbol: String {
        switch self {
        case .podcast: "antenna.radiowaves.left.and.right"
        case .advertisement: "megaphone"
        case .audiobook: "book.closed"
        case .drama: "bubble.left.and.bubble.right"
        case .game: "gamecontroller"
        case .narration: "text.book.closed"
        case .auto: "waveform"
        }
    }
}

public struct GenerationParams: Codable, Equatable, Sendable {
    public var format: String
    public var sampleRate: Int
    public var channels: Int
    public var volume: Int
    public var rate: Double
    public var seed: Int
    public var enableCBR: Bool
    public var bitRate: Int
    public var quality: Int
    public var enableAIGCTag: Bool

    public init(
        format: String = "wav",
        sampleRate: Int = 48000,
        channels: Int = 2,
        volume: Int = 50,
        rate: Double = 1.0,
        seed: Int = 42,
        enableCBR: Bool = false,
        bitRate: Int = 128,
        quality: Int = 5,
        enableAIGCTag: Bool = false
    ) {
        self.format = format
        self.sampleRate = sampleRate
        self.channels = channels
        self.volume = volume
        self.rate = rate
        self.seed = seed
        self.enableCBR = enableCBR
        self.bitRate = bitRate
        self.quality = quality
        self.enableAIGCTag = enableAIGCTag
    }
}

public struct ReferenceBinding: Codable, Equatable, Sendable {
    public var referenceID: String
    public var alias: String

    public init(referenceID: String, alias: String) {
        self.referenceID = referenceID
        self.alias = alias
    }
}

public enum StudioLayout {
    public static let minWidth = 1120
    public static let minHeight = 720
}

/// Clearly labeled shell-only examples. Task 3 replaces these with the 42 real templates.
public struct ShellPreviewTemplate: Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let subtitle: String
    public let topic: String
    public let script: String
    public let mode: CreationMode
    public let suggestedDuration: String

    public static let samples: [ShellPreviewTemplate] = [
        .init(id: 1, title: "雨夜陪伴", subtitle: "把忙碌的一天，轻轻放在雨声里。", topic: "雨声",
              script: "【场景】窗外的雨声渐渐落下。\n\n【角色：讲述者】温和、自然。\n\n【对白：讲述者】把忙碌的一天，轻轻放在雨声里。",
              mode: .podcast, suggestedDuration: "建议 45 秒"),
        .init(id: 2, title: "双人科技访谈", subtitle: "从一个具体问题展开轻巧、有来回的谈话。", topic: "科技",
              script: "【场景】安静的科技访谈录音间。\n\n【角色：主持人】好奇、清晰。\n\n【角色：嘉宾】从容、具体。\n\n【对白：主持人】今天的科技话题，从一个小问题开始。",
              mode: .podcast, suggestedDuration: "建议 50 秒"),
        .init(id: 3, title: "知识问答", subtitle: "用生活中的小疑问打开知识话题。", topic: "知识",
              script: "【场景】轻松的知识问答节目。\n\n【角色：讲述者】明快、亲切。\n\n【对白：讲述者】先从生活中的一个小疑问开始，找到背后的原理。",
              mode: .podcast, suggestedDuration: "建议 40 秒"),
    ]

    public static func sample(id: Int) -> ShellPreviewTemplate? {
        samples.first(where: { $0.id == id })
    }
}
