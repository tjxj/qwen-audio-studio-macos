import Foundation
import Testing
import AVFoundation
@testable import StudioCore

struct ReferenceAudioTests {
    @Test func unexpectedRemovalFailureKeepsJournalEvenWhenExistenceCheckWouldBeFalse() async throws {
        let (root, store, original) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.wav"); try wav(source, seconds: 1)
        let imported = try await original.importSource(url: source)
        let clip = try await original.prepare(importID: imported.id, start: 0, end: 1, persistent: false, name: "temporary")
        let service = try ReferenceAudioService(root: root.appendingPathComponent("audio"), store: store, fileRemover: DeleteThenReportFailure())
        await #expect(throws: CocoaError.self) { try await service.cleanup(now: Date().addingTimeInterval(7200)) }
        #expect(try await store.pendingReferenceCleanup().map(\.id) == [clip.snapshot.id])
        #expect(try await original.cleanup() == [clip.snapshot.id])
    }
    @Test func cleanupFinishesJournalAfterFileWasRemovedBeforeRestart() async throws {
        let (root, store, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.wav"); try wav(source, seconds: 1)
        let imported = try await service.importSource(url: source)
        let clip = try await service.prepare(importID: imported.id, start: 0, end: 1, persistent: false, name: "temporary")
        #expect(try await store.removeUnleasedTemporaryReference(clip.snapshot.id, idleBefore: Date().addingTimeInterval(7200)))
        try FileManager.default.removeItem(at: root.appendingPathComponent("audio").appendingPathComponent(clip.snapshot.relativePath))
        try await store.close()
        let reopened = try StudioStore(dataRoot: root.appendingPathComponent("db"))
        let retry = try ReferenceAudioService(root: root.appendingPathComponent("audio"), store: reopened)
        #expect(try await retry.cleanup() == [clip.snapshot.id])
        #expect(try await reopened.pendingReferenceCleanup().isEmpty)
    }
    @Test func failedCleanupRemainsRecoverableAndRetriesWithoutTouchingLeasedClip() async throws {
        let (root, store, sourceService) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.wav"); try wav(source, seconds: 1)
        let imported = try await sourceService.importSource(url: source)
        let clip = try await sourceService.prepare(importID: imported.id, start: 0, end: 1, persistent: false, name: "temporary")
        let file = root.appendingPathComponent("audio").appendingPathComponent(clip.snapshot.relativePath)
        let remover = FailFirstReferenceDeletion()
        let service = try ReferenceAudioService(root: root.appendingPathComponent("audio"), store: store, fileRemover: remover)
        let directory = DirectorySnapshot(id: "directory", version: 1, bookmark: Data([1]))
        try await store.saveDirectory(directory)
        let fields = DraftFields(prompt: "@voice1 synthetic", referenceBindings: [.init(referenceID: clip.snapshot.id, alias: "合成", slot: 1)], outputDirectoryID: directory.id)
        let project = try await store.createProject(fields: fields)
        let compiled = try PromptCompiler.compile(mode: fields.mode, prompt: fields.prompt, bindings: fields.referenceBindings)
        let request = UUID().uuidString
        let batch = try await store.createBatch(.init(clientRequestID: request, project: project, compiledPrompt: compiled.text,
            candidateSeeds: [1], directory: directory, references: [clip.snapshot],
            consent: .init(clientRequestID: request, references: [clip.snapshot], confirmed: true)))
        #expect(try await service.cleanup(now: Date().addingTimeInterval(7200)).isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try await store.getReference(id: clip.snapshot.id) == clip.snapshot)
        _ = try await store.cancelQueued(id: batch.jobIDs[0])
        await #expect(throws: CocoaError.self) { try await service.cleanup(now: Date().addingTimeInterval(7200)) }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try await store.pendingReferenceCleanup().map(\.id) == [clip.snapshot.id])
        await #expect(throws: StudioStoreError.staleReference) { try await store.saveReference(clip.snapshot) }
        // A reopened database/service must discover the failed deletion durably.
        try await store.close()
        let reopened = try StudioStore(dataRoot: root.appendingPathComponent("db"))
        let retry = try ReferenceAudioService(root: root.appendingPathComponent("audio"), store: reopened)
        _ = try await retry.cleanup(now: Date().addingTimeInterval(7200))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try await reopened.getReference(id: clip.snapshot.id) == nil)
        #expect(try await reopened.pendingReferenceCleanup().isEmpty)
    }
    func fixture() throws -> (URL, StudioStore, ReferenceAudioService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = try StudioStore(dataRoot: root.appendingPathComponent("db"))
        return (root, store, try ReferenceAudioService(root: root.appendingPathComponent("audio"), store: store))
    }
    func wav(_ url: URL, seconds: Double = 40, amplitude: Float = 0.4, toneStart: Double = 0) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(seconds * 16000))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][i] = Double(i) / 16000 < toneStart ? 0 : amplitude * Float(sin(Double(i) * 2 * .pi * 440 / 16000))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    @Test func fortySecondSourceRequiresExplicitTrimAndPreservesOriginal() async throws {
        let (root, _, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.wav"); try wav(source, toneStart: 12)
        let original = try Data(contentsOf: source)
        let imported = try await service.importSource(url: source)
        #expect(abs(imported.duration - 40) < 0.01)
        let clip = try await service.prepare(importID: imported.id, start: 12, end: 18, persistent: false, name: "合成片段")
        #expect(clip.snapshot.duration == 6)
        #expect(clip.snapshot.temporary)
        #expect(clip.mimeType == "audio/wav")
        #expect(clip.data[22] == 1 && clip.data[34] == 16)
        let selected = try await service.preview(importID: imported.id, start: 12, end: 18)
        #expect(selected.quality.rms > 0.2)
        let beginning = try await service.preview(importID: imported.id, start: 0, end: 6)
        #expect(beginning.quality.hints.contains(.silence))
        #expect(try Data(contentsOf: source) == original)
        #expect(try await service.library().isEmpty)
    }
    @Test func selectionBoundariesAndPersistentLibrary() async throws {
        let (root, _, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.wav"); try wav(source)
        let imported = try await service.importSource(url: source)
        for (start, end) in [(0.0,0.0), (0,30.001),(-1,6),(34,41),(Double.nan,2),(1,Double.infinity)] {
            await #expect(throws: ReferenceAudioError.invalidSelection) {
                try await service.prepare(importID: imported.id, start: start, end: end, persistent: false, name: "test")
            }
        }
        let clip = try await service.prepare(importID: imported.id, start: 0, end: 30, persistent: true, name: "保存的合成音色")
        #expect(clip.snapshot.duration == 30)
        #expect(!clip.snapshot.temporary)
        #expect(try await service.library().map(\.id) == [clip.snapshot.id])
    }
    @Test func rejectsContainerMismatchOversizeAndOverTenMinutes() async throws {
        let (root, _, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.wav"); try wav(original, seconds: 1)
        let mismatch = root.appendingPathComponent("synthetic.mp3"); try FileManager.default.copyItem(at: original, to: mismatch)
        await #expect(throws: ReferenceAudioError.containerMismatch) { try await service.importSource(url: mismatch) }
        let oversized = root.appendingPathComponent("large.wav")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized); try handle.truncate(atOffset: 50 * 1024 * 1024 + 1); try handle.close()
        await #expect(throws: ReferenceAudioError.sourceTooLarge) { try await service.importSource(url: oversized) }
        let long = root.appendingPathComponent("long.wav"); try wav(long, seconds: 600.01)
        await #expect(throws: ReferenceAudioError.sourceTooLong) { try await service.importSource(url: long) }
    }
    @Test func reportsSilenceLowVolumeAndClipping() {
        #expect(AudioSignalMeter.measure([0,0,0]).hints.contains(.silence))
        #expect(AudioSignalMeter.measure([0.001,-0.001,0.001]).hints.contains(.lowVolume))
        #expect(AudioSignalMeter.measure([1,-1,1,-1]).hints.contains(.clipping))
        #expect(AudioSignalMeter.measure([0.25,-0.25,0.2,-0.2]).hints.isEmpty)
    }
    @Test(arguments: ["wav", "mp3", "m4a", "ogg"])
    func decodesSyntheticCodecFixture(extension ext: String) async throws {
        let (root, _, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ReferenceAudio/tone.\(ext)")
        let imported = try await service.importSource(url: fixture)
        #expect(imported.duration >= 1.9 && imported.duration < 2.2)
        let prepared = try await service.prepare(importID: imported.id, start: 0.25, end: 1.25, persistent: false, name: "synthetic")
        #expect(abs(prepared.snapshot.duration - 1) < 0.001)
        let preview = try await service.preview(importID: imported.id, start: 0.25, end: 1.25)
        #expect(preview.duration == prepared.snapshot.duration)
        #expect(preview.quality.rms > 0.01)
    }
    @Test func twoJobsHoldSameTemporaryClipUntilBothRelease() async throws {
        let (root, store, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.wav"); try wav(source, seconds: 2)
        let imported = try await service.importSource(url: source)
        let clip = try await service.prepare(importID: imported.id, start: 0, end: 2, persistent: false, name: "temporary")
        let directory = DirectorySnapshot(id: "directory", version: 1, bookmark: Data([1]))
        try await store.saveDirectory(directory)
        let fields = DraftFields(name: "synthetic", mode: .narration, prompt: "@voice1 hello", referenceBindings: [.init(referenceID: clip.snapshot.id, alias: "合成", slot: 1)], outputDirectoryID: directory.id)
        let project = try await store.createProject(fields: fields)
        let compiled = try PromptCompiler.compile(mode: fields.mode, prompt: fields.prompt, bindings: fields.referenceBindings)
        let requestID = UUID().uuidString
        let confirmed = BatchSubmission(clientRequestID: requestID, project: project, compiledPrompt: compiled.text, candidateSeeds: [1,2], directory: directory, references: [clip.snapshot], consent: UploadConsent(clientRequestID: requestID, references: [clip.snapshot], confirmed: true))
        let batch = try await store.createBatch(confirmed)
        let leases = ReferenceLeaseStore(store: store)
        try await leases.acquire(clip.snapshot.id, forJob: batch.jobIDs[0])
        try await leases.acquire(clip.snapshot.id, forJob: batch.jobIDs[1])
        _ = try await service.cleanup(now: Date().addingTimeInterval(7200))
        #expect(try await store.getReference(id: clip.snapshot.id) != nil)
        try await leases.release(job: batch.jobIDs[0])
        _ = try await service.cleanup(now: Date().addingTimeInterval(7200))
        #expect(try await store.getReference(id: clip.snapshot.id) != nil)
        try await leases.release(job: batch.jobIDs[1])
        #expect(try await service.cleanup(now: Date().addingTimeInterval(3590)).isEmpty)
        _ = try await service.cleanup(now: Date().addingTimeInterval(7200))
        #expect(try await store.getReference(id: clip.snapshot.id) == nil)
    }
    @Test func longOpusDecodeRetainsTailAndSelectedFrames() async throws {
        let (root, _, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ReferenceAudio/long-tone.ogg")
        let imported = try await service.importSource(url: fixture)
        #expect(abs(imported.duration - 40) < 0.001)
        let selected = try await service.preview(importID: imported.id, start: 34, end: 40)
        #expect(selected.duration == 6)
        #expect(selected.quality.rms > 0.01)
    }
    @Test func savedLibrarySurvivesServiceReopenAndRejectsTamperedClip() async throws {
        let (root, store, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.wav"); try wav(source, seconds: 2)
        let imported = try await service.importSource(url: source)
        let clip = try await service.prepare(importID: imported.id, start: 0, end: 1, persistent: true, name: "saved")
        let reopened = try ReferenceAudioService(root: root.appendingPathComponent("audio"), store: store)
        #expect(try await reopened.library().map(\.id) == [clip.snapshot.id])
        #expect(try await reopened.prepared(referenceID: clip.snapshot.id).data == clip.data)
        #expect(try await reopened.cleanup(now: Date().addingTimeInterval(7200)).isEmpty)
        let file = root.appendingPathComponent("audio").appendingPathComponent(clip.snapshot.relativePath)
        try Data([1,2,3]).write(to: file)
        await #expect(throws: ReferenceAudioError.unavailable) { try await reopened.prepared(referenceID: clip.snapshot.id) }
    }
}

private final class FailFirstReferenceDeletion: ReferenceFileRemoving, @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    func remove(_ url: URL) throws {
        lock.lock(); let shouldFail = !failed; failed = true; lock.unlock()
        if shouldFail { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: url)
    }
}
private struct DeleteThenReportFailure: ReferenceFileRemoving {
    func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
        throw CocoaError(.fileWriteNoPermission)
    }
}
