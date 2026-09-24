import Foundation
import Testing
import StudioCore
@testable import QwenAudioStudioMacApp

@MainActor struct AudioPlaybackControllerTests {
    @Test func naturalEndLeavesPausedCompletionAndReplayRestartsAtZero() async throws {
        let audio = DecodedAudio(samples: Array(repeating: 0.2, count: 4_800), sampleRate: 24_000, contentHash: "short")
        let player = AudioPlaybackController(loader: { _ in audio })
        player.volume = 0
        defer { player.stop() }
        try await player.play(assetID: "short")
        try await Task.sleep(for: .milliseconds(450))
        #expect(player.state == .paused)
        #expect(abs(player.position - 0.2) < 0.02)
        try player.resume()
        #expect(player.state == .playing)
        #expect(player.position < 0.1)
    }

    @Test func comparisonSeeksAndLoopsWithinSharedFiveSecondRange() async throws {
        let a = tone(seconds: 5, hertz: 440), b = tone(seconds: 8, hertz: 880)
        let player = AudioPlaybackController(loader: { id in id == "a" ? a : b })
        player.volume = 0
        defer { player.stop() }
        try await player.play(assetID: "b")
        try player.setLoop(start: 6, end: 7)
        try await player.compare(assetA: "a", assetB: "b")
        #expect(!player.hasLoop)
        try player.switchToB()
        #expect(player.duration == 5)
        try player.seek(seconds: 7)
        #expect(player.position <= 5)
        #expect(throws: AudioPlaybackError.self) { try player.setLoop(start: 4.75, end: 5.25) }
        try player.setLoop(start: 4.0, end: 4.5)
        try player.switchToA()
        #expect(player.position <= 5)
    }
    @Test func delayedLoadCannotOverrideLaterPlaybackOrComparison() async throws {
        let gate = PlaybackLoaderGate()
        let short = tone(seconds: 5, hertz: 440)
        let long = tone(seconds: 8, hertz: 880)
        let player = AudioPlaybackController(loader: { id in
            if id == "slow" || id == "b" { return try await gate.wait(id) }
            return id == "c" ? long : short
        })
        player.volume = 0
        defer { player.stop() }
        let stalePlay = Task { try await player.play(assetID: "slow") }
        await gate.untilWaiting("slow")
        try await player.play(assetID: "a")
        gate.release("slow", with: long)
        await #expect(throws: AudioPlaybackError.self) { try await stalePlay.value }
        #expect(player.activeAssetID == "a")
        let staleCompare = Task { try await player.compare(assetA: "a", assetB: "b") }
        await gate.untilWaiting("b")
        try await player.play(assetID: "c")
        gate.release("b", with: short)
        await #expect(throws: AudioPlaybackError.self) { try await staleCompare.value }
        #expect(player.activeAssetID == "c")
        #expect(player.state == .playing)
    }
    @Test func fiveAndEightSecondTonesSwitchAtCommonPosition() async throws {
        let a = tone(seconds: 5, hertz: 440)
        let b = tone(seconds: 8, hertz: 880)
        let player = AudioPlaybackController(loader: { id in id == "a" ? a : b })
        player.volume = 0
        defer { player.stop() }
        try await player.play(assetID: "a")
        try player.seek(seconds: 1.25)
        let before = player.position
        try await player.compare(assetA: "a", assetB: "b")
        #expect(player.state == .paused)
        try player.switchToB()
        #expect(player.activeAssetID == "b")
        #expect(abs(player.position - before) <= 0.15)
        try player.switchToA()
        #expect(player.activeAssetID == "a")
        #expect(abs(player.position - before) <= 0.15)
        #expect(abs(estimatedFrequency(a.samples) - 440) < 5)
        #expect(abs(estimatedFrequency(b.samples) - 880) < 5)
    }

    @Test func seekBackVolumeLoopAndRouteChange() async throws {
        let a = tone(seconds: 5, hertz: 440)
        let player = AudioPlaybackController(loader: { _ in a })
        player.volume = 0
        defer { player.stop() }
        try await player.play(assetID: "a")
        try player.seek(seconds: 3)
        #expect(abs(player.position - 3) < 0.15)
        try player.backTenSeconds()
        #expect(player.position < 0.15)
        player.volume = 0.25
        #expect(player.volume == 0.25)
        #expect(throws: AudioPlaybackError.self) { try player.setLoop(start: 0.25, end: 0.74) }
        try player.setLoop(start: 0.25, end: 0.75)
        try player.seek(seconds: 0.70)
        try await Task.sleep(for: .milliseconds(300))
        #expect(player.position >= 0.25 && player.position < 0.75)
        player.handleRouteChange()
        #expect(player.state == .paused)
        let held = player.position
        try await Task.sleep(for: .milliseconds(50))
        #expect(abs(player.position - held) < 0.02)
        try player.resume()
        #expect(player.state == .playing)
    }

    @Test func missingAssetAndReferencePreviewNeverOverlapResultOwner() async throws {
        let a = tone(seconds: 5, hertz: 440)
        let transport = AudioPlaybackController(loader: { id in
            guard id == "a" else { throw AudioPlaybackError.missingAsset }
            return a
        })
        transport.volume = 0
        defer { transport.stop() }
        await #expect(throws: AudioPlaybackError.self) { try await transport.play(assetID: "missing") }
        #expect(transport.state == .failed)
        try await transport.play(assetID: "a")
        let reference = ReferencePlayback(transport: transport)
        try reference.play(wav(tone(seconds: 8, hertz: 880)), state: .source)
        #expect(transport.activeAssetID == nil)
        #expect(reference.state == .source)
        try await transport.play(assetID: "a")
        #expect(reference.state == .stopped)
        #expect(transport.activeAssetID == "a")
    }

    private func tone(seconds: Int, hertz: Double) -> DecodedAudio {
        let samples = (0..<(seconds * 24_000)).map { Float(0.5 * sin(2 * .pi * hertz * Double($0) / 24_000)) }
        return DecodedAudio(samples: samples, sampleRate: 24_000, contentHash: "synthetic-\(hertz)-\(seconds)")
    }
    private func estimatedFrequency(_ samples: [Float]) -> Double {
        let excerpt = samples.prefix(24_000)
        let crossings = zip(excerpt.dropFirst(), excerpt).filter { $0.0 >= 0 && $0.1 < 0 }.count
        return Double(crossings)
    }
    private func wav(_ audio: DecodedAudio) -> Data {
        var data = Data()
        func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + audio.samples.count * 2)); data.append(contentsOf: "WAVEfmt ".utf8)
        u32(16); u16(1); u16(1); u32(24_000); u32(48_000); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(audio.samples.count * 2))
        for sample in audio.samples { u16(UInt16(bitPattern: Int16((sample * 32767).rounded()))) }
        return data
    }
}

@MainActor private final class PlaybackLoaderGate {
    private var waiting: [String: CheckedContinuation<DecodedAudio, Error>] = [:]
    func wait(_ id: String) async throws -> DecodedAudio {
        try await withCheckedThrowingContinuation { waiting[id] = $0 }
    }
    func untilWaiting(_ id: String) async {
        for _ in 0..<100 where waiting[id] == nil { try? await Task.sleep(for: .milliseconds(5)) }
    }
    func release(_ id: String, with audio: DecodedAudio) { waiting.removeValue(forKey: id)?.resume(returning: audio) }
}
