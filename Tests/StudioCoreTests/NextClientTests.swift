import Foundation
import Testing
import Security
@testable import StudioCore

private final class RecordingProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var responder: @Sendable (URLRequest) -> (Int, Data) = { _ in (200, Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.lock()
        Self.requests.append(request)
        Self.bodies.append(body)
        let reply = Self.responder
        Self.lock.unlock()
        let (status, data) = reply(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func reset(_ response: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        lock.lock(); requests = []; bodies = []; responder = response; lock.unlock()
    }
    static func captured() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    static func capturedBodies() -> [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
}

private final class RedirectingProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seenSchemes: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.seenSchemes.append(request.url?.scheme ?? ""); Self.lock.unlock()
        let url = request.url!
        if url.scheme == "https" {
            let target = URL(string: "http://insecure.example.invalid/audio.wav?signature=synthetic")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("synthetic".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
    static func reset() { lock.lock(); seenSchemes = []; lock.unlock() }
    static func schemes() -> [String] { lock.lock(); defer { lock.unlock() }; return seenSchemes }
}

private struct TestCredentials: CredentialProviding {
    func load() throws -> NativeCredentials { NativeCredentials(apiKey: "synthetic-secret", workspaceID: "synthetic-workspace") }
}

private final class FaultyKeychainItems: KeychainItemAccess, @unchecked Sendable {
    var values: [String: String] = [:]
    var failedReads: Set<String> = []
    func read(service: String, account: String) throws -> String? {
        if failedReads.contains(service) { throw CredentialError.keychainFailure }
        return values[service]
    }
    func write(_ value: String, service: String, account: String) throws { values[service] = value }
}

@Suite(.serialized) struct NextClientTests {
    private func client() -> NextClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingProtocol.self]
        return NextClient(credentials: TestCredentials(), session: URLSession(configuration: config))
    }

    @Test func exactEndpointModelAndParameters() async throws {
        RecordingProtocol.reset { _ in
            (200, Data(#"{"request_id":"synthetic-request","output":{"audio":{"url":"https://audio.example.invalid/output.wav?private=signature","expires_at":1900000000,"duration":1.2}}}"#.utf8))
        }
        let result = try await client().synthesize(CompiledRequest(prompt: "合成测试", params: GenerationParams(format: "mp3", sampleRate: 48000, channels: 2, volume: 61, rate: 1.2, seed: 14, enableCBR: true, bitRate: 128, quality: 5, enableAIGCTag: true), seed: 17, references: []))
        let request = try #require(RecordingProtocol.captured().first)
        #expect(request.url?.absoluteString == "https://synthetic-workspace.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-secret")
        let body = try #require(RecordingProtocol.capturedBodies().first)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "qwen-audio-3.1-tts-next")
        let input = try #require(json["input"] as? [String: Any])
        #expect(input["text_prompt"] as? String == "合成测试")
        #expect(input["seed"] as? Int == 17)
        #expect(input["format"] as? String == "mp3")
        #expect(input["sample_rate"] as? Int == 48000)
        #expect(input["channels"] as? Int == 2)
        #expect(input["volume"] as? Int == 61)
        #expect(input["rate"] as? Double == 1.2)
        #expect(input["enable_cbr"] as? Bool == true)
        #expect(input["bit_rate"] as? Int == 128)
        #expect(input["enable_aigc_tag"] as? Bool == true)
        #expect(result.receipt.providerRequestID == "synthetic-request")
        #expect(result.receipt.expiresAt == Date(timeIntervalSince1970: 1900000000))
        #expect(!String(describing: result).contains("signature"))
    }

    @Test func credentialAndSignedURLNeverAppearInErrors() async throws {
        RecordingProtocol.reset { _ in (403, Data(#"{"message":"synthetic-secret https://audio.example.invalid/a?private=signature"}"#.utf8)) }
        do { _ = try await client().synthesize(CompiledRequest(prompt: "测试", params: .init(), seed: 1, references: [])); Issue.record("Expected HTTP failure") }
        catch {
            let description = String(describing: error) + error.localizedDescription
            #expect(!description.contains("synthetic-secret"))
            #expect(!description.contains("signature"))
            #expect(!description.contains("synthetic-workspace"))
        }
    }

    @Test func downloadRetriesOnlyGetAndNeverExposesSignedURL() async throws {
        let attempts = URLRequestCounter()
        RecordingProtocol.reset { request in
            attempts.record(request.httpMethod ?? "")
            return (503, Data(#"{"message":"https://signed.invalid/a?private=signature"}"#.utf8))
        }
        let downloader = NextAudioDownloader(protocolClasses: [RecordingProtocol.self])
        let receipt = ProviderResponseSnapshot(providerRequestID: "synthetic", audioURL: URL(string: "https://signed.invalid/a?private=signature")!)
        do { _ = try await downloader.download(receipt); Issue.record("Expected GET failure") }
        catch {
            #expect(attempts.methods == ["GET", "GET", "GET"])
            #expect(!error.localizedDescription.contains("signature"))
            #expect(!String(describing: error).contains("signed.invalid"))
        }
    }

    @Test func signedDownloadRedirectPolicyRejectsHTTPAndNonGET() throws {
        let session = URLSession(configuration: .ephemeral)
        let source = URL(string: "https://redirect.example.invalid/audio.wav?signature=synthetic")!
        var original = URLRequest(url: source); original.httpMethod = "GET"
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let policy = SecureDownloadRedirects()
        var accepted: URLRequest?
        var didComplete = false
        policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                          newRequest: URLRequest(url: URL(string: "http://insecure.example.invalid/audio.wav")!)) {
            accepted = $0; didComplete = true
        }
        #expect(didComplete && accepted == nil)
        var post = URLRequest(url: URL(string: "https://safe.example.invalid/audio.wav")!); post.httpMethod = "POST"
        didComplete = false
        policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: post) {
            accepted = $0; didComplete = true
        }
        #expect(didComplete && accepted == nil)
        let safe = URLRequest(url: URL(string: "https://safe.example.invalid/audio.wav")!)
        policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: safe) { accepted = $0 }
        #expect(accepted?.url == safe.url)
    }

    @Test func redirectFixtureProvesBaselineSessionWouldFollowHTTP() async throws {
        RedirectingProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedirectingProtocol.self]
        let session = URLSession(configuration: config)
        _ = try? await session.data(from: URL(string: "https://redirect.example.invalid/audio.wav?signature=synthetic")!)
        #expect(RedirectingProtocol.schemes().contains("http"))
    }

    @Test func disposableNativeKeychainItemRoundTripsAndDeletes() throws {
        guard ProcessInfo.processInfo.environment["QWEN_TEST_DISPOSABLE_KEYCHAIN"] == "1" else { return }
        let prefix = "QwenAudioStudio.Test." + UUID().uuidString
        let account = "synthetic-test-" + UUID().uuidString
        let store = NativeCredentialStore(account: account, servicePrefix: prefix)
        func delete(_ service: String) -> OSStatus {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service,
                           kSecAttrAccount as String: account] as CFDictionary)
        }
        defer { _ = delete(prefix + ".APIKey"); _ = delete(prefix + ".WorkspaceID"); _ = delete(prefix + ".Probe") }
        let probeStatus = SecItemAdd([kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: prefix + ".Probe",
                                      kSecAttrAccount as String: account,
                                      kSecValueData as String: Data("synthetic-probe".utf8),
                                      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
        #expect(probeStatus == errSecSuccess, "disposable keychain status: \(probeStatus)")
        try store.saveAPIKey("synthetic-key")
        try store.saveWorkspaceID("synthetic-workspace")
        #expect(try store.load().apiKey == "synthetic-key")
        try store.saveWorkspaceID("new-workspace")
        #expect(try store.load().apiKey == "synthetic-key")
        #expect(try store.load().workspaceID == "new-workspace")
        #expect(delete(prefix + ".APIKey") == errSecSuccess)
        #expect(delete(prefix + ".WorkspaceID") == errSecSuccess)
        #expect(throws: CredentialError.missing) { try store.load() }
    }

    @Test func legacyImportKeepsFirstFieldWhenSecondReadFailsAndPreservesNativeOtherField() throws {
        let access = FaultyKeychainItems()
        access.values["QwenAudioStudio.DashScopeAPIKey"] = "synthetic-legacy-key"
        access.values[NativeCredentialStore.workspaceService] = "native-workspace"
        access.failedReads.insert("QwenAudioStudio.WorkspaceID")
        let store = NativeCredentialStore(account: "synthetic", servicePrefix: "QwenAudioStudio.Native", items: access)
        let result = try store.importLegacy()
        #expect(result.apiKey)
        #expect(!result.workspaceID && result.failed)
        #expect(try store.load().apiKey == "synthetic-legacy-key")
        #expect(try store.load().workspaceID == "native-workspace")
    }

    @Test func legacyPrivateReceiptDecodesWithBoundedExpiry() throws {
        let old = #"{"providerRequestID":"synthetic","audioURL":"https://audio.example.invalid/a.wav?signature=private","receivedAt":800000000}"#
        let receipt = try JSONDecoder().decode(ProviderResponseSnapshot.self, from: Data(old.utf8))
        #expect(receipt.expiresAt.timeIntervalSince(receipt.receivedAt) == 24 * 3600)
        #expect(!String(describing: receipt).contains("signature"))
    }
}

private final class URLRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var methods: [String] { lock.lock(); defer { lock.unlock() }; return values }
}
