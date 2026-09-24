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
