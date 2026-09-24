import Foundation
import AVFoundation
import CryptoKit

public enum GenerationError: Error, LocalizedError, Sendable {
    case invalidSelection, referenceUnavailable, confirmationMismatch, consentExpired, downloadNotRetryable
    public var errorDescription: String? {
        switch self {
        case .invalidSelection: "提交内容已变化，请重新预检。"
        case .referenceUnavailable: "参考音频尚未准备好，请先完成原生音频处理。"
        case .confirmationMismatch: "确认内容已变化，请重新查看并确认。"
        case .consentExpired: "本次参考音频上传授权已过期，请重新确认。"
        case .downloadNotRetryable: "此任务没有可单独重试的下载。"
        }
    }
}

public struct GenerationInput: Sendable {
    public let clientRequestID: String
    public let project: ProjectDraft
    public let directory: DirectorySnapshot
    public var candidateCount: Int
    public let references: [ReferenceSnapshot]
    public let preparedReferences: [PreparedReference]
    public init(clientRequestID: String, project: ProjectDraft, directory: DirectorySnapshot, candidateCount: Int,
                references: [ReferenceSnapshot], preparedReferences: [PreparedReference]) {
        self.clientRequestID = clientRequestID; self.project = project; self.directory = directory
        self.candidateCount = candidateCount; self.references = references; self.preparedReferences = preparedReferences
    }
}

public struct GenerationPlan: Sendable {
    public let submission: BatchSubmission
    public let confirmationHash: String
    public let preparedReferences: [PreparedReference]
    public var prompt: String { submission.compiledPrompt }
    public var callCount: Int { submission.candidateSeeds.count }
    public var seeds: [Int] { submission.candidateSeeds }
    public var referenceNames: [String] { submission.references.map(\.fileName) }
    public var referenceDurations: [Double] { submission.references.map(\.duration) }
    public var directoryID: String { submission.directory.id }
}

public struct GenerationAuthorization: Sendable {
    public let confirmationHash: String
    public let clientRequestID: String
    public let submission: BatchSubmission
}

public protocol AudioDownloading: Sendable {
    func download(_ receipt: ProviderResponseSnapshot) async throws -> Data
}

public protocol BatchCommitting: Sendable {
    func createBatch(_ submission: BatchSubmission) async throws -> StoredBatch
}

private struct SQLiteBatchCommitter: BatchCommitting {
    let store: StudioStore
    func createBatch(_ submission: BatchSubmission) async throws -> StoredBatch {
        try await store.createBatch(submission)
    }
}

public struct NextAudioDownloader: AudioDownloading {
    private let session: URLSession
    public init() { self.session = Self.makeSession(protocolClasses: nil) }
    init(protocolClasses: [AnyClass]) { self.session = Self.makeSession(protocolClasses: protocolClasses) }
    private static func makeSession(protocolClasses: [AnyClass]?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration, delegate: SecureDownloadRedirects(), delegateQueue: nil)
    }
    public func download(_ receipt: ProviderResponseSnapshot) async throws -> Data {
        guard receipt.expiresAt > Date() else { throw NextClientError.expiredDownload }
        guard receipt.audioURL.scheme?.lowercased() == "https" else { throw NextClientError.downloadFailed }
        var request = URLRequest(url: receipt.audioURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      !data.isEmpty, data.count <= 100 * 1024 * 1024 else { throw NextClientError.downloadFailed }
                return data
            } catch {
                if attempt == 2 { throw NextClientError.downloadFailed }
            }
        }
        throw NextClientError.downloadFailed
    }
}

final class SecureDownloadRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https", request.httpMethod == "GET",
              task.originalRequest?.httpMethod == "GET" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public actor GenerationService {
    private enum AuthorizationState {
        case ready
        case committing(task: Task<StoredBatch, Error>, cancelRequested: Bool)
        case committed(batchID: String)
        case revoked(batchID: String)
    }
    private struct AuthorizationEntry {
        let previewHash: String
        let authorization: GenerationAuthorization
        var state: AuthorizationState
    }
    private let store: StudioStore
    private let directories: OutputDirectoryStore
    private let assets: GeneratedAssetStore
    private let synthesizer: any SynthesizerClient
    private let downloader: any AudioDownloading
    private let batchCommitter: any BatchCommitting
    private let now: @Sendable () -> Date
    private var authorizations: [String: AuthorizationEntry] = [:]
    private var cancelledBatchIDs: Set<String> = []

    public init(store: StudioStore, directories: OutputDirectoryStore, assets: GeneratedAssetStore,
                synthesizer: any SynthesizerClient, downloader: any AudioDownloading = NextAudioDownloader(),
                now: @escaping @Sendable () -> Date = Date.init,
                batchCommitter: (any BatchCommitting)? = nil) {
        self.store = store; self.directories = directories; self.assets = assets
        self.synthesizer = synthesizer; self.downloader = downloader; self.now = now
        self.batchCommitter = batchCommitter ?? SQLiteBatchCommitter(store: store)
    }

    public func preflight(_ input: GenerationInput) async throws -> GenerationPlan {
        guard !input.clientRequestID.isEmpty, (1...3).contains(input.candidateCount),
              input.project.fields.outputDirectoryID == input.directory.id,
              input.references.count <= 3 else { throw GenerationError.invalidSelection }
        guard input.references.count == input.preparedReferences.count,
              input.references == input.preparedReferences.map(\.snapshot) else { throw GenerationError.referenceUnavailable }
        let compiled = try PromptCompiler.compile(mode: input.project.fields.mode, prompt: input.project.fields.prompt,
                                                   bindings: input.project.fields.referenceBindings)
        guard compiled.bindings.map(\.referenceID) == input.references.map(\.id) else { throw GenerationError.invalidSelection }
        let seeds = try Self.seeds(startingAt: input.project.fields.params.seed, count: input.candidateCount)
        for prepared in input.preparedReferences {
            let digest = SHA256.hash(data: prepared.data).map { String(format: "%02x", $0) }.joined()
            guard prepared.snapshot.contentHash == digest else { throw GenerationError.referenceUnavailable }
            try PreparedWAVValidation.validate(prepared)
        }
        for seed in seeds {
            try NextRequestValidation.validate(CompiledRequest(prompt: compiled.text, params: input.project.fields.params,
                                                                seed: seed, references: input.preparedReferences))
        }
        let consent = UploadConsent(clientRequestID: input.clientRequestID, references: input.references,
                                    confirmed: false, confirmedAt: now())
        let submission = BatchSubmission(clientRequestID: input.clientRequestID, project: input.project,
                                         compiledPrompt: compiled.text, candidateSeeds: seeds, directory: input.directory,
                                         references: input.references, consent: consent)
        return GenerationPlan(submission: submission, confirmationHash: try submission.requestHash(),
                              preparedReferences: input.preparedReferences)
    }

    /// Invoke only from the visible charge-confirmation action. The random token
    /// is held inside this actor and is bound to the exact confirmed snapshot.
    public func confirm(_ plan: GenerationPlan) throws -> GenerationAuthorization {
        guard try plan.submission.requestHash() == plan.confirmationHash else { throw GenerationError.confirmationMismatch }
        if let existing = authorizations[plan.submission.clientRequestID] {
            guard existing.previewHash == plan.confirmationHash else { throw StudioStoreError.requestConflict }
            switch existing.state {
            case .committed: return existing.authorization
            case .revoked, .committing(_, true): throw GenerationError.confirmationMismatch
            case .committing(_, false): return existing.authorization
            case .ready: break
            }
            let consent = existing.authorization.submission.consent
            if consent.confirmedAt <= now(), consent.expiresAt > now() { return existing.authorization }
            authorizations.removeValue(forKey: plan.submission.clientRequestID)
        }
        let consent = UploadConsent(clientRequestID: plan.submission.clientRequestID, references: plan.submission.references,
                                    confirmed: true, confirmedAt: now())
        let submission = BatchSubmission(clientRequestID: plan.submission.clientRequestID, project: plan.submission.project,
                                         compiledPrompt: plan.submission.compiledPrompt,
                                         candidateSeeds: plan.submission.candidateSeeds, directory: plan.submission.directory,
                                         references: plan.submission.references, consent: consent)
        let requestHash = try submission.requestHash()
        let token = SHA256.hash(data: Data((requestHash + UUID().uuidString).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let authorization = GenerationAuthorization(confirmationHash: token,
                                                    clientRequestID: submission.clientRequestID, submission: submission)
        authorizations[submission.clientRequestID] = AuthorizationEntry(previewHash: plan.confirmationHash,
                                                                          authorization: authorization, state: .ready)
        return authorization
    }

    /// Dismissed charge sheets can invalidate an unused token. A submitted
    /// batch remains durable and cannot be revoked through this method.
    public func revokeAuthorization(_ authorization: GenerationAuthorization) {
        guard var stored = authorizations[authorization.clientRequestID],
              stored.authorization.confirmationHash == authorization.confirmationHash else { return }
        switch stored.state {
        case .ready: authorizations.removeValue(forKey: authorization.clientRequestID)
        case .committing(let task, _):
            stored.state = .committing(task: task, cancelRequested: true)
            authorizations[authorization.clientRequestID] = stored
        case .committed, .revoked: break
        }
    }

    public func submit(_ plan: GenerationPlan, confirmedHash: String, clientRequestID: String) async throws -> StoredBatch {
        guard clientRequestID == plan.submission.clientRequestID,
              try plan.submission.requestHash() == plan.confirmationHash,
              let stored = authorizations[clientRequestID], stored.previewHash == plan.confirmationHash,
              stored.authorization.confirmationHash == confirmedHash else { throw GenerationError.confirmationMismatch }
        let task: Task<StoredBatch, Error>
        switch stored.state {
        case .committed(let id):
            guard let batch = try await store.getBatch(id: id) else { throw StudioStoreError.corruptRecord }
            return batch
        case .revoked, .committing(_, true): throw GenerationError.confirmationMismatch
        case .ready:
            // Install the sole owner before yielding the actor. Reentrant calls
            // share its result and never enter the persistence boundary again.
            task = Task {
                try await self.commitAndExecute(plan, authorization: stored.authorization)
            }
            authorizations[clientRequestID]?.state = .committing(task: task, cancelRequested: false)
        case .committing(let existing, false): task = existing
        }
        // Any caller cancelling this same submission stops its queued work.
        // Forward cancellation synchronously so it cannot race an actor hop
        // after the commit returns and allow an unauthorized paid POST.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func commitAndExecute(_ plan: GenerationPlan, authorization: GenerationAuthorization) async throws -> StoredBatch {
        let clientRequestID = authorization.clientRequestID
        let confirmedHash = authorization.confirmationHash
        let confirmed = authorization.submission
        // createBatch durably commits the complete snapshot before any paid request.
        let batch: StoredBatch
        do { batch = try await batchCommitter.createBatch(confirmed) }
        catch {
            if var latest = authorizations[clientRequestID],
               latest.authorization.confirmationHash == confirmedHash {
                switch latest.state {
                case .committing(_, let cancelRequested):
                    if cancelRequested || Task.isCancelled {
                        authorizations.removeValue(forKey: clientRequestID)
                    } else {
                        latest.state = .ready
                        authorizations[clientRequestID] = latest
                    }
                case .ready, .committed, .revoked: break
                }
            }
            throw error
        }
        guard var latest = authorizations[clientRequestID],
              latest.authorization.confirmationHash == confirmedHash else {
            cancelledBatchIDs.insert(batch.id)
            for id in batch.jobIDs { _ = try? await store.cancelQueued(id: id) }
            throw GenerationError.confirmationMismatch
        }
        switch latest.state {
        case .committing(_, let cancelRequested):
            if cancelRequested || Task.isCancelled {
                latest.state = .revoked(batchID: batch.id)
                authorizations[clientRequestID] = latest
                cancelledBatchIDs.insert(batch.id)
                for id in batch.jobIDs { _ = try? await store.cancelQueued(id: id) }
                return batch
            }
            latest.state = .committed(batchID: batch.id)
            authorizations[clientRequestID] = latest
        case .committed(let id):
            guard let original = try await store.getBatch(id: id) else { throw StudioStoreError.corruptRecord }
            return original
        case .revoked:
            cancelledBatchIDs.insert(batch.id)
            for id in batch.jobIDs { _ = try? await store.cancelQueued(id: id) }
            throw GenerationError.confirmationMismatch
        case .ready:
            cancelledBatchIDs.insert(batch.id)
            for id in batch.jobIDs { _ = try? await store.cancelQueued(id: id) }
            throw GenerationError.confirmationMismatch
        }
        for (index, id) in batch.jobIDs.enumerated() {
            if Task.isCancelled { cancelledBatchIDs.insert(batch.id) }
            if cancelledBatchIDs.contains(batch.id) {
                _ = try? await store.cancelQueued(id: id)
                continue
            }
            guard try await store.claimJob(id: id) != nil else { continue }
            await execute(jobID: id, batchID: batch.id, index: index,
                          submission: confirmed, preparedReferences: plan.preparedReferences)
        }
        return batch
    }

    public func cancelQueued(_ id: String) async throws -> Bool { try await store.cancelQueued(id: id) }

    /// Stop all candidates that have not entered the paid request. An active
    /// request continues so its outcome can be recorded accurately.
    @discardableResult public func cancelBatch(batchID: String) async throws -> Int {
        guard let batch = try await store.getBatch(id: batchID) else { throw StudioStoreError.missing }
        cancelledBatchIDs.insert(batchID)
        var cancelled = 0
        for id in batch.jobIDs where try await store.cancelQueued(id: id) { cancelled += 1 }
        return cancelled
    }

    public func resumeDownload(jobID: String) async throws {
        guard let receipt = try await store.claimDownloadRetry(id: jobID),
              let job = try await store.getJob(id: jobID),
              let batch = try await store.getBatch(id: job.batchID) else { throw GenerationError.downloadNotRetryable }
        let lease: DirectoryLease
        do { lease = try await directories.resolveForJob(jobID, directoryID: batch.submission.directory.id) }
        catch {
            _ = try? await store.transitionJob(id: jobID, from: .downloading, to: .failed, message: "输出目录不可用，请重新授权后单独重试下载。")
            throw error
        }
        defer { lease.close() }
        await finishDownload(jobID: jobID, receipt: receipt, submission: batch.submission, lease: lease)
    }

    private func execute(jobID: String, batchID: String, index: Int,
                         submission batch: BatchSubmission, preparedReferences: [PreparedReference]) async {
        if Task.isCancelled || cancelledBatchIDs.contains(batchID) {
            _ = try? await store.transitionJob(id: jobID, from: .preparing, to: .failed, message: "批次已取消，未发送此候选。")
            return
        }
        guard batch.consent.expiresAt > now() else {
            _ = try? await store.transitionJob(id: jobID, from: .preparing, to: .failed, message: "本次上传授权已过期，请重新确认。")
            return
        }
        let lease: DirectoryLease
        do { lease = try await directories.resolveForJob(jobID, directoryID: batch.directory.id) }
        catch {
            _ = try? await store.transitionJob(id: jobID, from: .preparing, to: .failed, message: "输出目录不可用，请检查授权。")
            return
        }
        defer { lease.close() }
        // A queued job may wait while directory access is resolved. Consent is checked again at the final upload gate.
        guard batch.consent.expiresAt > now() else {
            _ = try? await store.transitionJob(id: jobID, from: .preparing, to: .failed, message: "本次上传授权已过期，请重新确认。")
            return
        }
        let referencesValid = preparedReferences.allSatisfy { prepared in
            let digest = SHA256.hash(data: prepared.data).map { String(format: "%02x", $0) }.joined()
            return digest == prepared.snapshot.contentHash && (try? PreparedWAVValidation.validate(prepared)) != nil
        }
        guard referencesValid else {
            _ = try? await store.transitionJob(id: jobID, from: .preparing, to: .failed, message: "参考音频校验失败，请重新准备并确认。")
            return
        }
        if Task.isCancelled || cancelledBatchIDs.contains(batchID) {
            _ = try? await store.transitionJob(id: jobID, from: .preparing, to: .failed, message: "批次已取消，未发送此候选。")
            return
        }
        do {
            guard try await store.transitionJob(id: jobID, from: .preparing, to: .requesting) else { return }
            if Task.isCancelled || cancelledBatchIDs.contains(batchID) {
                _ = try? await store.transitionJob(id: jobID, from: .requesting, to: .failed, message: "批次已取消，未发送此候选。")
                return
            }
            let request = CompiledRequest(prompt: batch.compiledPrompt, params: batch.project.fields.params,
                                          seed: batch.candidateSeeds[index], references: preparedReferences)
            let output: ProviderOutput
            do { output = try await synthesizer.synthesize(request) }
            catch {
                _ = try? await store.markResultUncertain(id: jobID, message: "付费请求结果待核查；不会自动重发。")
                return
            }
            guard try await store.recordProviderResponse(id: jobID, response: output.receipt) else { return }
            await finishDownload(jobID: jobID, receipt: output.receipt, submission: batch, lease: lease)
        } catch {
            _ = try? await store.markResultUncertain(id: jobID, message: "付费请求结果待核查；不会自动重发。")
        }
    }

    private func finishDownload(jobID: String, receipt: ProviderResponseSnapshot, submission: BatchSubmission,
                                lease: DirectoryLease) async {
        do {
            let existing = try await store.listAssets(jobID: jobID)
            let audioAsset = existing.first { $0.kind == "audio" }
            let data: Data
            if let audioAsset {
                let (registeredLease, url) = try await assets.resolveRegisteredAsset(audioAsset.id)
                defer { registeredLease.close() }
                data = try Data(contentsOf: url)
            } else {
                data = try await downloader.download(receipt)
            }
            guard try await store.transitionJob(id: jobID, from: .downloading, to: .validating) else { return }
            try NativeAudioValidation.validate(data, params: submission.project.fields.params,
                                               mode: submission.project.fields.mode)
            let format = submission.project.fields.params.format
            if audioAsset == nil {
                _ = try await assets.write(data: data, fileName: "audio.\(format)", kind: "audio", job: jobID, lease: lease)
            }
            let report = "model: qwen-audio-3.1-tts-next\nformat: \(format)\nstatus: validated\n"
            if !existing.contains(where: { $0.kind == "prompt" }) {
                _ = try await assets.write(data: Data(submission.compiledPrompt.utf8), fileName: "prompt.txt", kind: "prompt", job: jobID, lease: lease)
            }
            if !existing.contains(where: { $0.kind == "report" }) {
                _ = try await assets.write(data: Data(report.utf8), fileName: "report.txt", kind: "report", job: jobID, lease: lease)
            }
            _ = try await store.transitionJob(id: jobID, from: .validating, to: .success)
        } catch {
            let state = try? await store.getJob(id: jobID)?.state
            if state == .downloading || state == .validating {
                _ = try? await store.transitionJob(id: jobID, from: state!, to: .failed,
                    message: state == .downloading ? "音频下载失败，可单独重试下载。" : "音频验证或保存失败，请检查输出目录。")
            }
        }
    }

    private static func seeds(startingAt seed: Int, count: Int) throws -> [Int] {
        guard seed >= 0, seed <= Int.max - count + 1 else { throw GenerationError.invalidSelection }
        return (0..<count).map { seed + $0 }
    }
}

private enum PreparedWAVValidation {
    static func validate(_ reference: PreparedReference) throws {
        let bytes = reference.data
        guard reference.mimeType == "audio/wav", bytes.count >= 44, bytes.count <= 10 * 1024 * 1024,
              String(data: bytes.prefix(4), encoding: .ascii) == "RIFF",
              String(data: bytes[8..<12], encoding: .ascii) == "WAVE" else { throw GenerationError.referenceUnavailable }
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) }
        func u32(_ offset: Int) -> Int {
            Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) |
            (Int(bytes[offset + 2]) << 16) | (Int(bytes[offset + 3]) << 24)
        }
        guard u32(4) <= bytes.count - 8 else { throw GenerationError.referenceUnavailable }
        var format: (channels: Int, rate: Int, bits: Int)?
        var dataBytes: Int?
        var cursor = 12
        while cursor + 8 <= bytes.count {
            let size = u32(cursor + 4)
            guard size >= 0, size <= bytes.count - cursor - 8 else { throw GenerationError.referenceUnavailable }
            let tag = String(data: bytes[cursor..<(cursor + 4)], encoding: .ascii)
            if tag == "fmt " {
                guard size >= 16, u16(cursor + 8) == 1 else { throw GenerationError.referenceUnavailable }
                format = (u16(cursor + 10), u32(cursor + 12), u16(cursor + 22))
            } else if tag == "data" { dataBytes = size }
            cursor += 8 + size + (size & 1)
        }
        guard let format, let dataBytes, format.channels == 1, format.bits == 16,
              format.rate > 0, dataBytes > 0, dataBytes.isMultiple(of: 2) else { throw GenerationError.referenceUnavailable }
        let duration = Double(dataBytes) / Double(format.rate * 2)
        guard duration > 0, duration <= 30, abs(duration - reference.snapshot.duration) <= 0.1 else {
            throw GenerationError.referenceUnavailable
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-reference-" + UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try bytes.write(to: url, options: .atomic)
            let audio = try AVAudioFile(forReading: url)
            guard Int(audio.fileFormat.channelCount) == 1,
                  Int(audio.fileFormat.sampleRate) == format.rate,
                  abs(Double(audio.length) / audio.fileFormat.sampleRate - duration) <= 0.1 else {
                throw GenerationError.referenceUnavailable
            }
            let frames = AVAudioFrameCount(min(audio.length, 65536))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: frames) else {
                throw GenerationError.referenceUnavailable
            }
            var decoded: AVAudioFramePosition = 0
            while decoded < audio.length {
                try audio.read(into: buffer, frameCount: frames)
                guard buffer.frameLength > 0 else { throw GenerationError.referenceUnavailable }
                decoded += AVAudioFramePosition(buffer.frameLength)
            }
        } catch { throw GenerationError.referenceUnavailable }
    }
}

private enum NativeAudioValidation {
    static func validate(_ data: Data, params: GenerationParams, mode: CreationMode) throws {
        guard !data.isEmpty else { throw NextClientError.downloadFailed }
        let maxDuration = mode == .podcast ? 240.0 : 120.0
        if params.format == "pcm" {
            guard data.count >= params.channels * 2, data.count.isMultiple(of: params.channels * 2) else { throw NextClientError.invalidResponse }
            let duration = Double(data.count) / Double(params.sampleRate * params.channels * 2)
            guard duration > 0, duration <= maxDuration else { throw NextClientError.invalidResponse }
            return
        }
        if params.format == "wav" {
            guard data.count >= 44, String(data: data.prefix(4), encoding: .ascii) == "RIFF",
                  String(data: data[8..<12], encoding: .ascii) == "WAVE" else { throw NextClientError.invalidResponse }
        } else {
            let hasID3 = data.count >= 3 && String(data: data.prefix(3), encoding: .ascii) == "ID3"
            let hasFrame = data.count >= 2 && data[0] == 0xFF && data[1] & 0xE0 == 0xE0
            guard hasID3 || hasFrame else { throw NextClientError.invalidResponse }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-validate-" + UUID().uuidString + "." + params.format)
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: .atomic)
        let audio = try AVAudioFile(forReading: url)
        guard audio.length > 0, Int(audio.fileFormat.sampleRate) == params.sampleRate,
              Int(audio.fileFormat.channelCount) == params.channels,
              Double(audio.length) / audio.fileFormat.sampleRate <= maxDuration else { throw NextClientError.invalidResponse }
        let frameCount = AVAudioFrameCount(min(audio.length, 65536))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: frameCount) else { throw NextClientError.invalidResponse }
        var decoded: AVAudioFramePosition = 0
        while decoded < audio.length {
            try audio.read(into: buffer, frameCount: frameCount)
            guard buffer.frameLength > 0 else { throw NextClientError.invalidResponse }
            decoded += AVAudioFramePosition(buffer.frameLength)
        }
    }
}
