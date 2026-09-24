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
        try transport.setLoop(start: 0, end: 0.5)
        controller.loopEnabled = true
        controller.select("b", player: transport)
        #expect(controller.selectedID == "b")
        #expect(transport.state == .idle)
        #expect(transport.activeAssetID == nil)
        #expect(!controller.loopEnabled)
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
    @Test(arguments: ["prepare", "play", "construction"])
    func outputDeviceFailureKeepsDecodedAssetReadyForRetry(stage: String) async throws {
        let audio = DecodedAudio(samples: Array(repeating: 0.2, count: 24_000), sampleRate: 24_000, contentHash: "synthetic")
        let controller = ResultScreenController(candidates: [ResultCandidate(id: "a", number: 1, state: .success, assetID: "audio-a")],
            loader: { _ in audio })
        await controller.validate()
        let transport = AudioPlaybackController(loader: { _ in audio }, makeOutput: { _ in
            if stage == "construction" { throw AudioPlaybackError.outputUnavailable }
            return FakeAudioOutput(prepareSucceeds: stage != "prepare", playSucceeds: stage != "play")
        })
        await controller.play("a", player: transport)
        #expect(controller.rows[0].status == .ready)
        #expect(controller.rows[0].playable)
        #expect(controller.message?.contains("输出") == true)
    }
    @Test func comparisonOutputFailureKeepsBothAssetsReady() async {
        let audio = DecodedAudio(samples: Array(repeating: 0.2, count: 24_000), sampleRate: 24_000, contentHash: "synthetic")
        let controller = ResultScreenController(candidates: [
            ResultCandidate(id: "a", number: 1, state: .success, assetID: "audio-a"),
            ResultCandidate(id: "b", number: 2, state: .success, assetID: "audio-b")
        ], loader: { _ in audio })
        await controller.validate()
        let transport = AudioPlaybackController(loader: { _ in audio }, makeOutput: { _ in FakeAudioOutput(prepareSucceeds: false, playSucceeds: true) })
        await controller.compare(a: "a", b: "b", player: transport)
        #expect(controller.rows.allSatisfy { $0.playable })
        #expect(controller.message?.contains("输出") == true)
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
    @Test func invalidLoopToggleDoesNotPretendLoopIsActive() async throws {
        let audio = DecodedAudio(samples: Array(repeating: 0.2, count: 24_000), sampleRate: 24_000, contentHash: "synthetic")
        let player = AudioPlaybackController(loader: { _ in audio })
        player.volume = 0
        defer { player.stop() }
        let controller = ResultScreenController(candidates: [ResultCandidate(id: "a", number: 1, state: .success, assetID: "audio-a")], loader: { _ in audio })
        try await player.play(assetID: "audio-a")
        controller.setLoop(enabled: true, start: 0, end: 0.3, player: player)
        #expect(!controller.loopEnabled)
        controller.setLoop(enabled: true, start: 0, end: 0.5, player: player)
        #expect(controller.loopEnabled)
        controller.setLoop(enabled: false, start: 0, end: 0.5, player: player)
        #expect(!controller.loopEnabled)
    }
}

@MainActor private final class FakeAudioOutput: RealtimeAudioOutput {
    var volume: Float = 0
    var currentTime: TimeInterval = 0
    var isPlaying: Bool = false
    let prepareSucceeds: Bool
    let playSucceeds: Bool
    init(prepareSucceeds: Bool, playSucceeds: Bool) {
        self.prepareSucceeds = prepareSucceeds; self.playSucceeds = playSucceeds
    }
    func prepareToPlay() -> Bool { prepareSucceeds }
    func play() -> Bool { isPlaying = playSucceeds; return playSucceeds }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
}
