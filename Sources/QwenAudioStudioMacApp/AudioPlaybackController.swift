import Foundation
import AVFoundation
import CoreAudio
import Observation
import StudioCore

enum AudioPlaybackError: Error { case missingAsset, invalidLoop, unavailable, superseded, assetUnavailable, outputUnavailable }

@MainActor protocol RealtimeAudioOutput: AnyObject {
    var volume: Float { get set }
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    func prepareToPlay() -> Bool
    func play() -> Bool
    func pause()
    func stop()
}
extension AVAudioPlayer: RealtimeAudioOutput {}

/// The only real-time output owner, shared by results and reference previews.
@MainActor @Observable final class AudioPlaybackController {
    enum State: Equatable { case idle, preparing, paused, playing, failed }
    static let shared = AudioPlaybackController(loader: { _ in throw AudioPlaybackError.missingAsset })

    private var loader: (String) async throws -> DecodedAudio
    private let makeOutput: (Data) throws -> any RealtimeAudioOutput
    @ObservationIgnored private var player: (any RealtimeAudioOutput)?
    private var current: DecodedAudio?
    private var comparison: (a: DecodedAudio, b: DecodedAudio, aID: String, bID: String)?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var routeListener: AudioObjectPropertyListenerBlock?
    private var loop: (start: Double, end: Double)?
    private var heldPosition = 0.0
    private var operationGeneration = 0
    private var preview = false
    private(set) var state: State = .idle
    private(set) var activeAssetID: String?
    var volume: Float = 0.8 { didSet { player?.volume = max(0, min(1, volume)) } }
    var duration: Double {
        if let comparison { return min(comparison.a.duration, comparison.b.duration) }
        return current?.duration ?? 0
    }
    var hasLoop: Bool { loop != nil }
    var isPreview: Bool { preview }
    var position: Double {
        guard state == .playing, let player else { return heldPosition }
        return min(duration, player.currentTime)
    }

    init(loader: @escaping (String) async throws -> DecodedAudio,
         makeOutput: @escaping (Data) throws -> any RealtimeAudioOutput = { try AVAudioPlayer(data: $0) }) {
        self.loader = loader; self.makeOutput = makeOutput
    }
    func startMonitoringRoute() {
        guard routeListener == nil else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.handleRouteChange() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
            routeListener = listener
        }
    }
    func configure(assets: GeneratedAssetStore) {
        configure(loader: { id in try await assets.decodeRegisteredAudio(id) })
    }
    func configure(loader: @escaping (String) async throws -> DecodedAudio) {
        stop(); self.loader = loader
    }
    func play(assetID: String) async throws {
        stop(); state = .preparing
        let token = operationGeneration
        let decoded: DecodedAudio
        do { decoded = try await loader(assetID) }
        catch {
            guard token == operationGeneration else { throw AudioPlaybackError.superseded }
            stop(); state = .failed
            throw AudioPlaybackError.assetUnavailable
        }
        guard token == operationGeneration else { throw AudioPlaybackError.superseded }
        do {
            guard decoded.sampleRate == AudioDecoder.playbackRate else { throw AudioPlaybackError.assetUnavailable }
            current = decoded; activeAssetID = assetID
            try start(at: 0)
        } catch { if token == operationGeneration { stop(); state = .failed }; throw error }
    }
    func playPreview(data: Data) throws {
        stop(); state = .preparing
        do {
            current = try AudioDecoder.decode(data: data)
            preview = true
            try start(at: 0)
        } catch { stop(); state = .failed; throw error }
    }
    func compare(assetA: String, assetB: String) async throws {
        let time = (activeAssetID == assetA || activeAssetID == assetB) ? position : 0
        operationGeneration += 1
        let token = operationGeneration
        pause(); clearLoop(); state = .preparing
        let a: DecodedAudio, b: DecodedAudio
        do { a = try await loader(assetA); b = try await loader(assetB) }
        catch {
            guard token == operationGeneration else { throw AudioPlaybackError.superseded }
            stop(); state = .failed
            throw AudioPlaybackError.assetUnavailable
        }
        guard token == operationGeneration else { throw AudioPlaybackError.superseded }
        comparison = (a, b, assetA, assetB)
        current = a; activeAssetID = assetA; preview = false
        heldPosition = min(time, a.duration, b.duration)
        state = .paused
    }
    func switchToA() throws { try switchTo(.a) }
    func switchToB() throws { try switchTo(.b) }
    private enum Side { case a, b }
    private func switchTo(_ side: Side) throws {
        guard let comparison else { throw AudioPlaybackError.unavailable }
        let time = min(position, comparison.a.duration, comparison.b.duration)
        current = side == .a ? comparison.a : comparison.b
        activeAssetID = side == .a ? comparison.aID : comparison.bID
        try start(at: time)
    }
    func seek(seconds: Double) throws {
        guard current != nil, seconds.isFinite else { throw AudioPlaybackError.unavailable }
        let target = max(0, min(duration, seconds))
        heldPosition = target
        if let player { player.currentTime = target }
    }
    func backTenSeconds() throws { try seek(seconds: position - 10) }
    func setLoop(start: Double, end: Double) throws {
        guard current != nil, start.isFinite, end.isFinite, start >= 0, end - start >= 0.5,
              end <= duration else { throw AudioPlaybackError.invalidLoop }
        loop = (start, end)
        if position < start || position >= end { try seek(seconds: start) }
        if state == .playing { beginLoopMonitor() }
    }
    func clearLoop() { loop = nil; loopTask?.cancel(); loopTask = nil }
    func pause() {
        guard state == .playing else { return }
        heldPosition = position
        player?.pause(); loopTask?.cancel(); loopTask = nil
        state = .paused
    }
    func resume() throws {
        guard state == .paused else { return }
        if heldPosition >= duration - 0.001 { try start(at: 0); return }
        if let player {
            player.currentTime = heldPosition
            guard player.play() else { throw AudioPlaybackError.outputUnavailable }
            state = .playing; beginLoopMonitor()
        } else { try start(at: heldPosition) }
    }
    func stop() {
        operationGeneration += 1
        loopTask?.cancel(); loopTask = nil
        player?.stop(); player = nil
        current = nil; comparison = nil; loop = nil
        heldPosition = 0; activeAssetID = nil; preview = false; state = .idle
    }
    func handleRouteChange() {
        guard state == .playing else { return }
        heldPosition = position
        loopTask?.cancel(); loopTask = nil
        player?.stop(); player = nil
        state = .paused
    }
    private func start(at time: Double) throws {
        guard let current else { throw AudioPlaybackError.unavailable }
        // Old output is stopped before a new player is allocated or started.
        player?.stop(); player = nil
        loopTask?.cancel(); loopTask = nil
        let output: any RealtimeAudioOutput
        do { output = try makeOutput(Self.wav(current)) }
        catch { throw AudioPlaybackError.outputUnavailable }
        output.volume = max(0, min(1, volume))
        guard output.prepareToPlay() else { throw AudioPlaybackError.outputUnavailable }
        let target = max(0, min(duration, time))
        output.currentTime = target
        guard output.play() else { throw AudioPlaybackError.outputUnavailable }
        player = output; heldPosition = target; state = .playing
        beginLoopMonitor()
    }
    private func beginLoopMonitor() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.state == .playing, let player = self.player else { return }
                if let loop = self.loop, player.currentTime >= loop.end {
                    if player.isPlaying { player.currentTime = loop.start; self.heldPosition = loop.start }
                    else { try? self.start(at: loop.start); return }
                } else if !player.isPlaying || player.currentTime >= self.duration - 0.001 {
                    self.heldPosition = self.duration
                    player.stop(); self.player = nil; self.state = .paused
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }
    private static func wav(_ audio: DecodedAudio) -> Data {
        var data = Data()
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        let count = audio.samples.count
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + count * 2)); data.append(contentsOf: "WAVEfmt ".utf8)
        u32(16); u16(1); u16(1); u32(UInt32(audio.sampleRate)); u32(UInt32(audio.sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(count * 2))
        for sample in audio.samples {
            let scaled = Int16((max(-1, min(1, sample)) * 32767).rounded())
            u16(UInt16(bitPattern: scaled))
        }
        return data
    }
}
