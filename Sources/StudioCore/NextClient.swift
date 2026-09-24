import Foundation

public enum NextClientError: Error, LocalizedError, Sendable {
    case invalidRequest, transport, httpStatus(Int), invalidResponse, expiredDownload, downloadFailed
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "生成参数无效，请检查后重试。"
        case .transport: "网络请求结果未能确认，请在记录中核查。"
        case .httpStatus(let code): "服务返回 HTTP \(code)；请求结果请在记录中核查。"
        case .invalidResponse: "服务响应不完整；请求结果请在记录中核查。"
        case .expiredDownload: "下载链接已过期。"
        case .downloadFailed: "音频下载失败，可单独重试下载。"
        }
    }
}

public struct PreparedReference: Sendable {
    public let snapshot: ReferenceSnapshot
    public let mimeType: String
    public let data: Data
    public init(snapshot: ReferenceSnapshot, mimeType: String, data: Data) {
        self.snapshot = snapshot; self.mimeType = mimeType; self.data = data
    }
}

public struct CompiledRequest: Sendable {
    public let prompt: String
    public let params: GenerationParams
    public let seed: Int
    public let references: [PreparedReference]
    public init(prompt: String, params: GenerationParams, seed: Int, references: [PreparedReference]) {
        self.prompt = prompt; self.params = params; self.seed = seed; self.references = references
    }
}

public struct ProviderOutput: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let receipt: ProviderResponseSnapshot
    public init(receipt: ProviderResponseSnapshot) { self.receipt = receipt }
    public var description: String { "ProviderOutput(<redacted>)" }
    public var debugDescription: String { description }
}

public protocol SynthesizerClient: Sendable {
    func synthesize(_ request: CompiledRequest) async throws -> ProviderOutput
}

public struct NextClient: SynthesizerClient {
    private let credentials: any CredentialProviding
    private let session: URLSession
    public init(credentials: any CredentialProviding = NativeCredentialStore(), session: URLSession? = nil) {
        self.credentials = credentials
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: NoPostRedirects(), delegateQueue: nil)
    }

    public func synthesize(_ request: CompiledRequest) async throws -> ProviderOutput {
        let identity = try credentials.load()
        guard NativeCredentialStore.validWorkspaceID(identity.workspaceID), !identity.apiKey.isEmpty else { throw NextClientError.invalidRequest }
        try NextRequestValidation.validate(request)
        guard let endpoint = URL(string: "https://\(identity.workspaceID).cn-beijing.maas.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer") else { throw NextClientError.invalidRequest }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("Bearer \(identity.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(Body(request: request))
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: urlRequest) }
        catch { throw NextClientError.transport }
        guard let http = response as? HTTPURLResponse, http.url?.host == endpoint.host else { throw NextClientError.invalidResponse }
        guard http.statusCode == 200 else { throw NextClientError.httpStatus(http.statusCode) }
        guard let parsed = try? JSONDecoder().decode(Response.self, from: data),
              !parsed.requestID.isEmpty, parsed.requestID.utf8.count <= 128,
              parsed.requestID.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let audioURL = URL(string: parsed.output.audio.url),
              audioURL.scheme?.lowercased() == "https", audioURL.host?.isEmpty == false,
              parsed.output.audio.expiresAt > Date().timeIntervalSince1970 else { throw NextClientError.invalidResponse }
        return ProviderOutput(receipt: ProviderResponseSnapshot(providerRequestID: parsed.requestID,
            audioURL: audioURL, expiresAt: Date(timeIntervalSince1970: parsed.output.audio.expiresAt)))
    }

    private struct Body: Encodable {
        let model = "qwen-audio-3.1-tts-next"
        let input: Input
        init(request: CompiledRequest) { input = Input(request: request) }
        struct Input: Encodable {
            let textPrompt: String; let references: [Reference]
            let format: String; let sampleRate: Int; let channels: Int; let volume: Int; let rate: Double
            let seed: Int; let enableCBR: Bool; let bitRate: Int; let quality: Int; let enableAIGCTag: Bool
            init(request: CompiledRequest) {
                let p = request.params
                textPrompt = request.prompt
                references = request.references.map { Reference(audioData: "data:\($0.mimeType);base64,\($0.data.base64EncodedString())") }
                format = p.format; sampleRate = p.sampleRate; channels = p.channels; volume = p.volume; rate = p.rate
                seed = request.seed; enableCBR = p.enableCBR; bitRate = p.bitRate; quality = p.quality; enableAIGCTag = p.enableAIGCTag
            }
            enum CodingKeys: String, CodingKey {
                case textPrompt = "text_prompt", references, format, sampleRate = "sample_rate", channels, volume, rate, seed
                case enableCBR = "enable_cbr", bitRate = "bit_rate", quality, enableAIGCTag = "enable_aigc_tag"
            }
        }
        struct Reference: Encodable { let audioData: String; enum CodingKeys: String, CodingKey { case audioData = "audio_data" } }
    }
    private struct Response: Decodable {
        let requestID: String; let output: Output
        enum CodingKeys: String, CodingKey { case requestID = "request_id", output }
        struct Output: Decodable { let audio: Audio }
        struct Audio: Decodable { let url: String; let expiresAt: Double; enum CodingKeys: String, CodingKey { case url, expiresAt = "expires_at" } }
    }
}

private final class NoPostRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum NextRequestValidation {
    private static let cbrBands: [Int: Set<Int>] = [
        8000: [8, 16, 24, 32, 40, 48, 56, 64],
        16000: [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
        24000: [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
        44100: [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
        48000: [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    ]
    public static func validate(_ request: CompiledRequest) throws {
        let p = request.params
        guard !request.prompt.isEmpty, request.prompt.unicodeScalars.count <= 3000,
              ["wav", "mp3", "pcm"].contains(p.format), cbrBands[p.sampleRate] != nil,
              [1, 2].contains(p.channels), (0...100).contains(p.volume), p.rate.isFinite,
              (0.5...2).contains(p.rate), (0...9).contains(p.quality),
              request.references.count <= 3 else { throw NextClientError.invalidRequest }
        if p.format == "mp3" && p.enableCBR && !cbrBands[p.sampleRate, default: []].contains(p.bitRate) { throw NextClientError.invalidRequest }
        for reference in request.references {
            guard (0...10 * 1024 * 1024).contains(reference.data.count), !reference.data.isEmpty,
                  reference.snapshot.duration > 0, reference.snapshot.duration <= 30,
                  ["audio/wav", "audio/mpeg", "audio/ogg"].contains(reference.mimeType) else { throw NextClientError.invalidRequest }
        }
    }
}
