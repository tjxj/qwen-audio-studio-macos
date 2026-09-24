import Testing
import Foundation
import StudioCore
@testable import QwenAudioStudioMacApp

@MainActor struct ResultScreenTests {
    @Test func everyCandidateStartsUnverifiedAndOnlyDecodedAudioBecomesPlayable() async {
        let items = [
            ResultCandidate(id: "job1", number: 1, state: .success, assetID: "audio1"),
            ResultCandidate(id: "job2", number: 2, state: .success, assetID: "missing"),
            ResultCandidate(id: "job3", number: 3, state: .failed, assetID: nil),
        ]
        let controller = ResultScreenController(candidates: items, loader: { id in
            guard id == "audio1" else { throw AudioPlaybackError.missingAsset }
            return DecodedAudio(samples: [0.25, -0.25], sampleRate: 24_000, contentHash: "verified-hash")
        })
        #expect(controller.rows.count == 3)
        #expect(controller.rows.allSatisfy { !$0.playable })
        await controller.validate()
        #expect(controller.rows.map(\.playable) == [true, false, false])
        #expect(controller.rows[0].duration != nil)
        #expect(controller.rows[1].status == .unavailable)
    }
    @Test func selectingAnotherRowStopsOldAudibleCandidate() async throws {
        let audio = DecodedAudio(samples: Array(repeating: 0.2, count: 24_000), sampleRate: 24_000, contentHash: "synthetic")
        let transport = AudioPlaybackController(loader: { _ in audio })
        transport.volume = 0
        defer { transport.stop() }
        let controller = ResultScreenController(candidates: [
            ResultCandidate(id: "a", number: 1, state: .success, assetID: "audio-a"),
            ResultCandidate(id: "b", number: 2, state: .success, assetID: "audio-b")
        ], loader: { _ in audio })
        try await transport.play(assetID: "audio-a")
        controller.select("b", player: transport)
        #expect(controller.selectedID == "b")
        #expect(transport.state == .idle)
        #expect(transport.activeAssetID == nil)
    }
    @Test func fileLostAfterValidationMarksPreviouslyReadyRowUnavailable() async throws {
        let audio = DecodedAudio(samples: Array(repeating: 0.2, count: 24_000), sampleRate: 24_000, contentHash: "synthetic")
        let controller = ResultScreenController(candidates: [ResultCandidate(id: "a", number: 1, state: .success, assetID: "audio-a")],
            loader: { _ in audio })
        await controller.validate()
        #expect(controller.rows[0].playable)
        let transport = AudioPlaybackController(loader: { _ in throw AudioPlaybackError.missingAsset })
        await controller.play("a", player: transport)
        #expect(controller.rows[0].status == .unavailable)
        #expect(!controller.rows[0].playable)
    }
    @Test func comparisonSelectionTracksAudibleSide() async {
        let controller = ResultScreenController(candidates: [
            ResultCandidate(id: "a", number: 1, state: .success, assetID: "audio-a"),
            ResultCandidate(id: "b", number: 2, state: .success, assetID: "audio-b")
        ], loader: { _ in DecodedAudio(samples: [0.2], sampleRate: 24_000, contentHash: "synthetic") })
        controller.beginComparison(a: "a", b: "b")
        controller.selectComparisonSide(.b)
        #expect(controller.selectedID == "b")
        controller.selectComparisonSide(.a)
        #expect(controller.selectedID == "a")
    }
}
