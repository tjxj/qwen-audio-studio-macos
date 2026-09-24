import Foundation
import AVFoundation
import Testing
@testable import StudioCore

struct AudioPlaybackTests {
    @Test func distinctSyntheticTonesDecodeToActualPCMAndDistinctHashes() throws {
        let a = try tone(seconds: 5, hertz: 440)
        let b = try tone(seconds: 8, hertz: 880)
        let decodedA = try AudioDecoder.decode(data: a)
        let decodedB = try AudioDecoder.decode(data: b)
        #expect(abs(decodedA.duration - 5) < 0.002)
        #expect(abs(decodedB.duration - 8) < 0.002)
        #expect(decodedA.contentHash != decodedB.contentHash)
        #expect(decodedA.samples.contains { abs($0) > 0.2 })
        #expect(decodedB.samples.contains { abs($0) > 0.2 })
    }

    @Test func waveformUsesContentHashAndRejectsReplacedBytes() throws {
        let cache = WaveformCache()
        let a = try AudioDecoder.decode(data: tone(seconds: 5, hertz: 440))
        let b = try AudioDecoder.decode(data: tone(seconds: 5, hertz: 880))
        let first = cache.envelope(for: a, bins: 100)
        #expect(first.count == 100)
        #expect(cache.entryCount == 1)
        _ = cache.envelope(for: a, bins: 100)
        #expect(cache.entryCount == 1)
        _ = cache.envelope(for: b, bins: 100)
        #expect(cache.entryCount == 2)
    }

    @Test func corruptAudioCannotBeMarkedPlayable() throws {
        #expect(throws: AudioDecodeError.self) { try AudioDecoder.decode(data: Data("fake.wav".utf8)) }
    }

    @Test(arguments: ["wav", "mp3", "m4a", "ogg"])
    func verifiedCodecFixturesProduceTwoSecondsOfRealSamples(ext: String) throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ReferenceAudio/tone.\(ext)")
        let decoded = try AudioDecoder.decode(data: Data(contentsOf: fixture))
        #expect((1.9...2.2).contains(decoded.duration))
        #expect(decoded.samples.contains { abs($0) > 0.05 })
    }

    @Test func wavPCM16ReadsLittleEndianStereoAndResamples() throws {
        let input = pcm16WAV(rate: 16_000, channels: 2, samples: [16384, -16384, -16384, 16384])
        let decoded = try AudioDecoder.decode(data: input)
        #expect(decoded.sampleRate == 24_000)
        #expect(decoded.samples.count == 3)
        #expect(decoded.samples.allSatisfy { abs($0) < 0.0001 })
        let mono = try AudioDecoder.decode(data: pcm16WAV(rate: 24_000, channels: 1, samples: [16384, -16384]))
        #expect(abs(mono.samples[0] - 0.5) < 0.001)
        #expect(abs(mono.samples[1] + 0.5) < 0.001)
    }

    @Test func rawPCMMustHaveStoredFormatAndDecodesStereoSamples() throws {
        var bytes = Data()
        for sample in [Int16(16384), -16384, -16384, 16384] {
            var little = sample.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        #expect(throws: AudioDecodeError.self) { try AudioDecoder.decode(data: bytes) }
        let decoded = try AudioDecoder.decode(data: bytes, rawPCMFormat: RawPCMFormat(sampleRate: 16_000, channels: 2))
        #expect(decoded.samples.count == 3)
        #expect(decoded.samples.allSatisfy { abs($0) < 0.0001 })
        #expect(throws: AudioDecodeError.self) { try AudioDecoder.decode(data: bytes.dropLast(), rawPCMFormat: RawPCMFormat(sampleRate: 16_000, channels: 2)) }
    }

    @Test func wavRejectsTruncatedChunksAndUnsupportedPCMDepth() throws {
        let good = pcm16WAV(rate: 24_000, channels: 1, samples: [16384, -16384])
        #expect(throws: AudioDecodeError.self) { try AudioDecoder.decode(data: good.dropLast()) }
        var badLength = good
        badLength.replaceSubrange(4..<8, with: [255, 255, 255, 127])
        #expect(throws: AudioDecodeError.self) { try AudioDecoder.decode(data: badLength) }
        var badDepth = good
        badDepth.replaceSubrange(34..<36, with: [24, 0])
        #expect(throws: AudioDecodeError.self) { try AudioDecoder.decode(data: badDepth) }
    }

    @Test(arguments: ["mp3", "m4a"])
    func compressedContainerTruncationNeverYieldsPlayablePCM(ext: String) throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ReferenceAudio/tone.\(ext)")
        let complete = try Data(contentsOf: fixture)
        let truncated = Data(complete.prefix(complete.count / 2))
        let rejected: Bool
        do { _ = try AudioDecoder.decode(data: truncated); rejected = false }
        catch { rejected = true }
        #expect(rejected)
    }

    private func tone(seconds: Int, hertz: Double) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 24_000))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][i] = Float(0.5 * sin(2 * .pi * hertz * Double(i) / 24_000))
        }
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }

    private func pcm16WAV(rate: UInt32, channels: UInt16, samples: [Int16]) -> Data {
        var data = Data()
        func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + samples.count * 2)); data.append(contentsOf: "WAVEfmt ".utf8)
        u32(16); u16(1); u16(channels); u32(rate); u32(rate * UInt32(channels) * 2); u16(channels * 2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(samples.count * 2))
        for sample in samples { u16(UInt16(bitPattern: sample)) }
        return data
    }
}
