import Foundation
import AVFoundation
import CryptoKit
import COpusBridge

public enum AudioDecodeError: Error, Equatable, Sendable { case unsupported, invalidAudio, tooLarge }

public struct DecodedAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let contentHash: String
    public var duration: Double { Double(samples.count) / sampleRate }
    public init(samples: [Float], sampleRate: Double, contentHash: String) {
        self.samples = samples; self.sampleRate = sampleRate; self.contentHash = contentHash
    }
}

public struct RawPCMFormat: Sendable {
    public let sampleRate: Int
    public let channels: Int
    public init(sampleRate: Int, channels: Int) { self.sampleRate = sampleRate; self.channels = channels }
}

public enum AudioDecoder {
    public static let playbackRate = 24_000.0
    public static func decode(data: Data, rawPCMFormat: RawPCMFormat? = nil) throws -> DecodedAudio {
        guard !data.isEmpty, data.count <= 256 * 1024 * 1024 else { throw AudioDecodeError.tooLarge }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let rawPCMFormat {
            let samples = try decodeRawPCM(data, format: rawPCMFormat)
            return DecodedAudio(samples: samples, sampleRate: playbackRate, contentHash: hash)
        }
        let ext: String
        if data.count >= 12, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) { ext = "wav" }
        else if data.prefix(3) == Data("ID3".utf8) || (data.count >= 2 && data[0] == 255 && data[1] & 0xE0 == 0xE0) { ext = "mp3" }
        else if data.count >= 8, data[4..<8] == Data("ftyp".utf8) { ext = "m4a" }
        else if data.prefix(4) == Data("OggS".utf8), data.prefix(512).range(of: Data("OpusHead".utf8)) != nil { ext = "ogg" }
        else { throw AudioDecodeError.unsupported }
        if ext == "mp3" { try validateMP3DeclaredLength(data) }
        let samples = try ext == "wav" ? decodeWAV(data) : (ext == "ogg" ? decodeOpus(data) : decodeNative(data, ext: ext))
        guard !samples.isEmpty, samples.count <= Int(playbackRate * 60 * 60), samples.allSatisfy(\.isFinite) else { throw AudioDecodeError.invalidAudio }
        return DecodedAudio(samples: samples, sampleRate: playbackRate, contentHash: hash)
    }
    private static func decodeRawPCM(_ data: Data, format: RawPCMFormat) throws -> [Float] {
        guard [8000, 16000, 24000, 44100, 48000].contains(format.sampleRate),
              (1...2).contains(format.channels), data.count.isMultiple(of: format.channels * 2),
              data.count >= format.channels * 2 else { throw AudioDecodeError.invalidAudio }
        let bytes = [UInt8](data)
        let frames = bytes.count / (format.channels * 2)
        guard frames <= format.sampleRate * 3600 else { throw AudioDecodeError.tooLarge }
        var samples = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var total: Float = 0
            for channel in 0..<format.channels {
                let at = (frame * format.channels + channel) * 2
                let bits = UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
                total += Float(Int16(bitPattern: bits)) / 32768
            }
            samples[frame] = total / Float(format.channels)
        }
        return try resample(samples, sourceRate: format.sampleRate)
    }
    private static func validateMP3DeclaredLength(_ data: Data) throws {
        let bytes = [UInt8](data)
        var audioStart = 0
        if bytes.prefix(3).elementsEqual(Array("ID3".utf8)) {
            guard bytes.count >= 10, bytes[6..<10].allSatisfy({ $0 < 128 }) else { throw AudioDecodeError.invalidAudio }
            audioStart = 10 + (Int(bytes[6]) << 21) + (Int(bytes[7]) << 14) + (Int(bytes[8]) << 7) + Int(bytes[9])
            guard audioStart + 4 <= bytes.count else { throw AudioDecodeError.invalidAudio }
        }
        let searchEnd = min(bytes.count, audioStart + 256)
        guard searchEnd >= audioStart + 12 else { throw AudioDecodeError.invalidAudio }
        for offset in audioStart..<(searchEnd - 12) {
            let marker = bytes[offset..<(offset + 4)]
            if marker.elementsEqual(Array("Xing".utf8)) || marker.elementsEqual(Array("Info".utf8)) {
                let flags = (UInt32(bytes[offset + 4]) << 24) | (UInt32(bytes[offset + 5]) << 16)
                    | (UInt32(bytes[offset + 6]) << 8) | UInt32(bytes[offset + 7])
                var cursor = offset + 8
                if flags & 1 != 0 { cursor += 4 }
                if flags & 2 != 0 {
                    guard cursor + 4 <= bytes.count else { throw AudioDecodeError.invalidAudio }
                    let declared = (UInt32(bytes[cursor]) << 24) | (UInt32(bytes[cursor + 1]) << 16)
                        | (UInt32(bytes[cursor + 2]) << 8) | UInt32(bytes[cursor + 3])
                    guard declared > 0, Int(declared) <= bytes.count - audioStart else { throw AudioDecodeError.invalidAudio }
                }
                return
            }
        }
    }

    /// PCM WAV can be decoded without entering CoreAudio while the output graph
    /// is playing. Bounds and chunk alignment are checked before each read.
    private static func decodeWAV(_ data: Data) throws -> [Float] {
        let bytes = [UInt8](data)
        func u16(_ at: Int) throws -> UInt16 {
            guard at >= 0, at + 2 <= bytes.count else { throw AudioDecodeError.invalidAudio }
            return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
        }
        func u32(_ at: Int) throws -> UInt32 {
            guard at >= 0, at + 4 <= bytes.count else { throw AudioDecodeError.invalidAudio }
            return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        guard bytes.count >= 44, 8 + Int(try u32(4)) == bytes.count else { throw AudioDecodeError.invalidAudio }
        var offset = 12
        var formatCode: UInt16?, channels: Int?, rate: Int?, bits: Int?, blockAlign: Int?
        var payload: Range<Int>?
        while offset + 8 <= bytes.count {
            let size = Int(try u32(offset + 4))
            guard size >= 0, size <= bytes.count - offset - 8 else { throw AudioDecodeError.invalidAudio }
            let range = (offset + 8)..<(offset + 8 + size)
            if bytes[offset..<(offset + 4)].elementsEqual(Array("fmt ".utf8)) {
                guard formatCode == nil else { throw AudioDecodeError.invalidAudio }
                guard size >= 16 else { throw AudioDecodeError.invalidAudio }
                formatCode = try u16(range.lowerBound)
                channels = Int(try u16(range.lowerBound + 2))
                rate = Int(try u32(range.lowerBound + 4))
                blockAlign = Int(try u16(range.lowerBound + 12))
                bits = Int(try u16(range.lowerBound + 14))
            }
            if bytes[offset..<(offset + 4)].elementsEqual(Array("data".utf8)) {
                guard payload == nil else { throw AudioDecodeError.invalidAudio }
                payload = range
            }
            offset = range.upperBound + size % 2
        }
        guard offset == bytes.count, let formatCode, let channels, let rate, let bits, let blockAlign, let payload,
              channels > 0, channels <= 8, rate >= 8000, rate <= 192000,
              [(UInt16(1), 16), (UInt16(3), 32)].contains(where: { $0.0 == formatCode && $0.1 == bits }),
              blockAlign == channels * bits / 8, payload.count > 0, payload.count % blockAlign == 0 else { throw AudioDecodeError.invalidAudio }
        let frames = payload.count / blockAlign
        guard frames <= rate * 3600 else { throw AudioDecodeError.tooLarge }
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            let position = payload.lowerBound + frame * blockAlign
            var value: Float = 0
            for channel in 0..<channels {
                let at = position + channel * bits / 8
                if formatCode == 1 { value += Float(Int16(bitPattern: try u16(at))) / 32768 }
                else { value += Float(bitPattern: try u32(at)) }
            }
            let sample = value / Float(channels)
            guard sample.isFinite, abs(sample) <= 4 else { throw AudioDecodeError.invalidAudio }
            mono[frame] = sample
        }
        return try resample(mono, sourceRate: rate)
    }
    private static func resample(_ samples: [Float], sourceRate rate: Int) throws -> [Float] {
        if Double(rate) == playbackRate { return samples }
        let frames = samples.count
        let count = Int((Double(frames) * playbackRate / Double(rate)).rounded())
        guard count > 0, count <= Int(playbackRate * 3600) else { throw AudioDecodeError.tooLarge }
        return (0..<count).map { index in
            let source = Double(index) * Double(rate) / playbackRate
            let left = min(frames - 1, Int(source))
            let right = min(frames - 1, left + 1)
            let blend = Float(source - Double(left))
            return samples[left] * (1 - blend) + samples[right] * blend
        }
    }

    private static func decodeNative(_ data: Data, ext: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-playback-\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0, file.processingFormat.channelCount > 0 else { throw AudioDecodeError.invalidAudio }
            let source = file.processingFormat
            let target = AVAudioFormat(standardFormatWithSampleRate: playbackRate, channels: 1)!
            let converter = AVAudioConverter(from: source, to: target)!
            var output = [Float](), consumed = false, readFrames: Int64 = 0
            var readFailure: Error?
            var empty = 0
            while true {
                let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192)!
                var error: NSError?
                let state = converter.convert(to: buffer, error: &error) { count, status in
                    if consumed || file.framePosition >= file.length { consumed = true; status.pointee = .endOfStream; return nil }
                    let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: min(count, 8192))!
                    do { try file.read(into: input) }
                    catch { readFailure = error; status.pointee = .endOfStream; return nil }
                    if input.frameLength == 0 { consumed = true; status.pointee = .endOfStream; return nil }
                    readFrames += Int64(input.frameLength)
                    status.pointee = .haveData; return input
                }
                guard readFailure == nil, error == nil, state != .error else { throw AudioDecodeError.invalidAudio }
                if buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] {
                    output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                    empty = 0
                } else { empty += 1 }
                guard output.count <= Int(playbackRate * 60 * 60), empty < 16 else { throw AudioDecodeError.tooLarge }
                if state == .endOfStream { break }
            }
            guard readFrames == file.length else { throw AudioDecodeError.invalidAudio }
            return output
        } catch let error as AudioDecodeError { throw error }
        catch { throw AudioDecodeError.invalidAudio }
    }

    private static func decodeOpus(_ data: Data) throws -> [Float] {
        try data.withUnsafeBytes { bytes in
            var frames: Int64 = 0, channels: Int32 = 0
            guard let raw = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  let decoder = qwen_opus_open(raw, data.count, &frames, &channels),
                  frames > 0, frames <= 48_000 * 3600 else { throw AudioDecodeError.invalidAudio }
            defer { qwen_opus_close(decoder) }
            var stereo = [Float](repeating: 0, count: 8192 * 2)
            let source = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let target = AVAudioFormat(standardFormatWithSampleRate: playbackRate, channels: 1)!
            let converter = AVAudioConverter(from: source, to: target)!
            var output = [Float](), ended = false, read: Int64 = 0, empty = 0
            while true {
                let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192)!
                var error: NSError?
                let state = converter.convert(to: buffer, error: &error) { count, status in
                    if ended { status.pointee = .endOfStream; return nil }
                    let n = qwen_opus_read(decoder, &stereo, Int32(min(Int(count), 8192) * 2))
                    if n <= 0 { ended = true; status.pointee = .endOfStream; return nil }
                    read += Int64(n)
                    let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(n))!
                    input.frameLength = AVAudioFrameCount(n)
                    for i in 0..<Int(n) { input.floatChannelData![0][i] = (stereo[2*i] + stereo[2*i+1]) / 2 }
                    status.pointee = .haveData; return input
                }
                guard error == nil, state != .error else { throw AudioDecodeError.invalidAudio }
                if buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] {
                    output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                    empty = 0
                } else { empty += 1 }
                guard output.count <= Int(playbackRate * 3600), empty < 16 else { throw AudioDecodeError.tooLarge }
                if state == .endOfStream { break }
            }
            guard read == frames else { throw AudioDecodeError.invalidAudio }
            return output
        }
    }
}

public final class WaveformCache: @unchecked Sendable {
    private var entries: [String: [Float]] = [:]
    private let lock = NSLock()
    public var entryCount: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    public init() {}
    public func envelope(for audio: DecodedAudio, bins: Int) -> [Float] {
        guard bins > 0, bins <= 4096 else { return [] }
        let key = "peak-v1:\(audio.contentHash):\(bins)"
        lock.lock(); defer { lock.unlock() }
        if let hit = entries[key] { return hit }
        let values = (0..<bins).map { index -> Float in
            let start = index * audio.samples.count / bins
            let end = min(audio.samples.count, (index + 1) * audio.samples.count / bins)
            guard end > start else { return 0 }
            return audio.samples[start..<end].reduce(0) { max($0, abs($1)) }
        }
        entries[key] = values
        return values
    }
}
