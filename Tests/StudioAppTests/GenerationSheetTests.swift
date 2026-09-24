import Foundation
import Testing
@testable import StudioCore
@testable import QwenAudioStudioMacApp

private actor DelayedAuthorization {
    private var continuation: CheckedContinuation<GenerationAuthorization, Error>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    func confirm() async throws -> GenerationAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            startWaiter?.resume()
            startWaiter = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release(_ authorization: GenerationAuthorization) {
        continuation?.resume(returning: authorization)
        continuation = nil
    }
}

private actor RevocationRecorder {
    private(set) var tokens: [String] = []
    func record(_ authorization: GenerationAuthorization) { tokens.append(authorization.confirmationHash) }
}

@MainActor @Suite(.serialized)
struct GenerationSheetTests {
    @Test func confirmationUsesStableVoiceSlotAfterGap() {
        let fields = DraftFields(referenceBindings: [
            ReferenceBinding(referenceID: "speaker-a", alias: "甲", slot: 1),
            ReferenceBinding(referenceID: "speaker-c", alias: "丙", slot: 3)
        ])
        #expect(GenerationSheet.referenceDisplaySlot(referenceID: "speaker-c", fields: fields) == 3)
    }
    private func authorization() -> GenerationAuthorization {
        let project = ProjectDraft(fields: DraftFields(prompt: "合成测试"))
        let directory = DirectorySnapshot(id: "synthetic-dir", version: 1, bookmark: Data([1]))
        let consent = UploadConsent(clientRequestID: "synthetic-request", references: [], confirmed: true)
        let submission = BatchSubmission(clientRequestID: "synthetic-request", project: project,
            compiledPrompt: "合成测试", candidateSeeds: [1], directory: directory, references: [], consent: consent)
        return GenerationAuthorization(confirmationHash: "synthetic-token", clientRequestID: "synthetic-request", submission: submission)
    }

    @Test func cancelWhileConfirmationAwaitsSuppressesCallbackAndRevokesToken() async {
        let gate = DelayedAuthorization()
        let revoked = RevocationRecorder()
        let controller = GenerationConfirmationController()
        var callbackCount = 0
        let work = controller.begin(confirm: { try await gate.confirm() },
            revoke: { await revoked.record($0) }, onConfirmed: { _ in callbackCount += 1 })
        await gate.waitUntilStarted()
        controller.cancel()
        await gate.release(authorization())
        await work.value
        #expect(callbackCount == 0)
        #expect(await revoked.tokens == ["synthetic-token"])
    }

    @Test func disappearWhileConfirmationAwaitsSuppressesCallbackAndRevokesToken() async {
        let gate = DelayedAuthorization()
        let revoked = RevocationRecorder()
        let controller = GenerationConfirmationController()
        var callbackCount = 0
        let work = controller.begin(confirm: { try await gate.confirm() },
            revoke: { await revoked.record($0) }, onConfirmed: { _ in callbackCount += 1 })
        await gate.waitUntilStarted()
        controller.disappear()
        await gate.release(authorization())
        await work.value
        #expect(callbackCount == 0)
        #expect(await revoked.tokens == ["synthetic-token"])
    }
}
