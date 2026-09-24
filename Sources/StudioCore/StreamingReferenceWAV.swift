import Foundation
import AVFoundation

/// Holds one converter output chunk and its PCM16 encoding, never the full source.
final class StreamingReferenceWAV {
    private let handle: FileHandle
    private let rate: Int
    private var meter = AudioSignalAccumulator()
    private(set) var frameCount = 0
    var quality: AudioSignalQuality { meter.quality }
    init(url: URL, rate: Int) throws {
        self.rate = rate
        try Self.header(frames: 0, rate: rate).write(to: url, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }
    deinit { try? handle.close() }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let samples = buffer.floatChannelData?[0] else { throw ReferenceAudioError.decodeFailed }
        let count = Int(buffer.frameLength)
        guard frameCount + count <= rate * 600 else { throw ReferenceAudioError.sourceTooLong }
        var bytes = Data(count: count * 2)
        try bytes.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let sample = samples[i]
                guard sample.isFinite else { throw ReferenceAudioError.decodeFailed }
                meter.append(sample)
                words[i] = Int16((max(-1, min(1, sample)) * 32767).rounded()).littleEndian
            }
        }
        try handle.write(contentsOf: bytes)
        frameCount += count
    }
    func finish() throws {
        guard frameCount > 0 else { throw ReferenceAudioError.decodeFailed }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(frames: frameCount, rate: rate))
        try handle.close()
    }
    private static func header(frames: Int, rate: Int) -> Data {
        var data = Data()
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(frames * 2 + 36)); data.append(contentsOf: "WAVEfmt ".utf8)
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(frames * 2))
        return data
    }
}
