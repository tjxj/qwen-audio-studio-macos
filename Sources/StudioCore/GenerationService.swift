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

public protocol AudioDownloading: Sendable {
    func download(_ receipt: ProviderResponseSnapshot) async throws -> Data
}

public struct NextAudioDownloader: AudioDownloading {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
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

public actor GenerationService {
    private let store: StudioStore
    private let directories: OutputDirectoryStore
    private let assets: GeneratedAssetStore
    private let synthesizer: any SynthesizerClient
    private let downloader: any AudioDownloading
    private let now: @Sendable () -> Date

    public init(store: StudioStore, directories: OutputDirectoryStore, assets: GeneratedAssetStore,
                synthesizer: any SynthesizerClient, downloader: any AudioDownloading = NextAudioDownloader(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.directories = directories; self.assets = assets
        self.synthesizer = synthesizer; self.downloader = downloader; self.now = now
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
        }
        for seed in seeds {
            try NextRequestValidation.validate(CompiledRequest(prompt: compiled.text, params: input.project.fields.params,
                                                                seed: seed, references: input.preparedReferences))
        }
        let consent = UploadConsent(clientRequestID: input.clientRequestID, references: input.references,
                                    confirmed: true, confirmedAt: now())
        let submission = BatchSubmission(clientRequestID: input.clientRequestID, project: input.project,
                                         compiledPrompt: compiled.text, candidateSeeds: seeds, directory: input.directory,
                                         references: input.references, consent: consent)
        return GenerationPlan(submission: submission, confirmationHash: try submission.requestHash(),
                              preparedReferences: input.preparedReferences)
    }

    public func submit(_ plan: GenerationPlan, confirmedHash: String, clientRequestID: String) async throws -> StoredBatch {
        guard confirmedHash == plan.confirmationHash, clientRequestID == plan.submission.clientRequestID,
              try plan.submission.requestHash() == plan.confirmationHash else { throw GenerationError.confirmationMismatch }
        // createBatch durably commits the complete snapshot before any paid request.
        let batch = try await store.createBatch(plan.submission)
        for (index, id) in batch.jobIDs.enumerated() {
            guard try await store.claimJob(id: id) != nil else { continue }
            await execute(jobID: id, index: index, plan: plan)
        }
        return batch
    }

    public func cancelQueued(_ id: String) async throws -> Bool { try await store.cancelQueued(id: id) }

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

    private func execute(jobID: String, index: Int, plan: GenerationPlan) async {
        let batch = plan.submission
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
        let hashesMatch = plan.preparedReferences.allSatisfy { prepared in
            SHA256.hash(data: prepared.data).map { String(format: "%02x", $0) }.joined() == prepared.snapshot.contentHash
        }
        guard hashesMatch else {
            _ = try? await store.transitionJob(id: jobID, from: .preparing, to: .failed, message: "参考音频校验失败，请重新准备并确认。")
            return
        }
        do {
            guard try await store.transitionJob(id: jobID, from: .preparing, to: .requesting) else { return }
            let request = CompiledRequest(prompt: batch.compiledPrompt, params: batch.project.fields.params,
                                          seed: batch.candidateSeeds[index], references: plan.preparedReferences)
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
