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
}
