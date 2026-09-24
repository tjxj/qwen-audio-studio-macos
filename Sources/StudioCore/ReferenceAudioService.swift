import Foundation
import AVFoundation
import CryptoKit
import COpusBridge

public enum ReferenceAudioError: Error, Equatable, Sendable {
    case unavailable, invalidSelection, containerMismatch, sourceTooLarge, sourceTooLong, decodeFailed
}
public struct ImportedReference: Identifiable, Sendable {
    public let id: String
    public let fileName: String
    public let duration: Double
    public let sampleRate: Double
    public let channels: Int
    public let quality: AudioSignalQuality
}
public struct ReferencePreview: Sendable {
    public let data: Data
    public let duration: Double
    public let quality: AudioSignalQuality
}
public actor ReferenceAudioService {
    private let root: URL
    private let store: StudioStore
    private let fileRemover: any ReferenceFileRemoving
    private var imports: [String: ImportedReference] = [:]
    private let rate = 24000.0
    public init(root: URL, store: StudioStore, fileRemover: any ReferenceFileRemoving = LocalReferenceFileRemover()) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root; self.store = store; self.fileRemover = fileRemover
    }
    public func importSource(url: URL) throws -> ImportedReference {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let limit = 50 * 1024 * 1024
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw ReferenceAudioError.unavailable }
        guard (values.fileSize ?? Int.max) <= limit else { throw ReferenceAudioError.sourceTooLarge }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let ext = url.pathExtension.lowercased()
        try Self.validateContainer(try handle.read(upToCount: 512) ?? Data(), ext: ext)
        try handle.seek(toOffset: 0)
        let id = UUID().uuidString
        let copy = root.appendingPathComponent("decode_\(id).\(ext)")
        defer { try? FileManager.default.removeItem(at: copy) }
        try Data().write(to: copy, options: .withoutOverwriting)
        let destination = try FileHandle(forWritingTo: copy)
        defer { try? destination.close() }
        var copied = 0
        while true {
            let count: Int = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { return 0 }
                copied += chunk.count
                guard copied <= limit else { throw ReferenceAudioError.sourceTooLarge }
                try destination.write(contentsOf: chunk)
                return chunk.count
            }
            if count == 0 { break }
        }
        try destination.close()
        let outputURL = importURL(id)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: outputURL) } }
        let writer = try StreamingReferenceWAV(url: outputURL, rate: Int(rate))
        let decoded = ext == "ogg" ? try decodeOpus(copy, writer: writer) : try decodeNative(copy, writer: writer)
        try writer.finish()
        let duration = Double(writer.frameCount) / rate
        guard duration > 0, duration <= 600 else { throw ReferenceAudioError.sourceTooLong }
        let imported = ImportedReference(id: id, fileName: url.lastPathComponent, duration: duration,
            sampleRate: decoded.rate, channels: decoded.channels, quality: writer.quality)
        imports[id] = imported
        completed = true
        return imported
    }
    public func prepare(importID: String, start: Double, end: Double, persistent: Bool, name: String) async throws -> PreparedReference {
        let preview = try preview(importID: importID, start: start, end: end)
        guard preview.data.count <= 10 * 1024 * 1024 else { throw ReferenceAudioError.invalidSelection }
        let id = UUID().uuidString, relative = "clip_" + UUID().uuidString + ".wav"
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = ReferenceSnapshot(id: id, contentHash: Self.hash(preview.data),
            fileName: (cleanName.isEmpty ? "参考音色" : String(cleanName.prefix(120))) + ".wav",
            duration: preview.duration, relativePath: relative, temporary: !persistent)
        let file = root.appendingPathComponent(relative)
        try preview.data.write(to: file, options: .withoutOverwriting)
        do { try await store.saveReference(snapshot) }
        catch { try? FileManager.default.removeItem(at: file); throw error }
        return PreparedReference(snapshot: snapshot, mimeType: "audio/wav", data: preview.data)
    }
    public func preview(importID: String, start: Double, end: Double) throws -> ReferencePreview {
        guard let imported = imports[importID] else { throw ReferenceAudioError.unavailable }
        guard start.isFinite, end.isFinite, start >= 0, end > start,
              end <= imported.duration + 0.000001, end - start <= 30 else { throw ReferenceAudioError.invalidSelection }
        let samples = try selectedSamples(id: importID, start: start, end: end)
        guard !samples.isEmpty else { throw ReferenceAudioError.invalidSelection }
        return ReferencePreview(data: Self.wav(samples, rate: Int(rate)), duration: Double(samples.count) / rate,
                                quality: AudioSignalMeter.measure(samples))
    }
    /// The complete decoded source is available for local playback, including sources over 30 seconds.
    public func sourcePreview(importID: String) throws -> Data {
        guard imports[importID] != nil else { throw ReferenceAudioError.unavailable }
        let url = importURL(importID)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return try Data(contentsOf: url)
    }
    public func library() async throws -> [ReferenceSnapshot] { try await store.listReferences().filter { !$0.temporary } }
    public func prepared(referenceID: String) async throws -> PreparedReference {
        guard let reference = try await store.getReference(id: referenceID) else { throw ReferenceAudioError.unavailable }
        let data = try Data(contentsOf: clipURL(reference))
        guard Self.hash(data) == reference.contentHash else { throw ReferenceAudioError.unavailable }
        try await store.touchReference(referenceID)
        return PreparedReference(snapshot: reference, mimeType: "audio/wav", data: data)
    }
    public func cleanup(now: Date = Date()) async throws -> [String] {
        let cutoff = now.addingTimeInterval(-3600)
        var removed: [String] = []
        for reference in try await store.listReferences() where reference.temporary {
            _ = try clipURL(reference)
            _ = try await store.removeUnleasedTemporaryReference(reference.id, idleBefore: cutoff)
        }
        // A failed deletion remains registered here, even across process restart.
        // A claimed reference is no longer available for new batch leases.
        for reference in try await store.pendingReferenceCleanup() {
            let url = try clipURL(reference)
            do { try fileRemover.remove(url) }
            catch {
                let failure = error as NSError
                let missing = failure.domain == NSCocoaErrorDomain &&
                    [CocoaError.Code.fileNoSuchFile.rawValue, CocoaError.Code.fileReadNoSuchFile.rawValue].contains(failure.code)
                guard missing || (failure.domain == NSPOSIXErrorDomain && failure.code == Int(POSIXErrorCode.ENOENT.rawValue)) else { throw error }
            }
            try await store.finishReferenceCleanup(reference.id)
            removed.append(reference.id)
        }
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("import_"), UUID(uuidString: String(name.dropFirst(7))) != nil,
                  let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date <= cutoff else { continue }
            try FileManager.default.removeItem(at: url)
            imports.removeValue(forKey: String(name.dropFirst(7)))
        }
        return removed
    }
    private func clipURL(_ reference: ReferenceSnapshot) throws -> URL {
        let name = reference.relativePath
        guard name.hasPrefix("clip_"), name.hasSuffix(".wav"),
              UUID(uuidString: String(name.dropFirst(5).dropLast(4))) != nil else { throw ReferenceAudioError.unavailable }
        let url = root.appendingPathComponent(name)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else { throw ReferenceAudioError.unavailable }
        return url
    }
    private func importURL(_ id: String) -> URL { root.appendingPathComponent("import_\(id).wav") }
    private func selectedSamples(id: String, start: Double, end: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: importURL(id))
        let first = Int64((start * rate).rounded()), last = Int64((end * rate).rounded())
        guard last > first, last <= file.length else { throw ReferenceAudioError.invalidSelection }
        file.framePosition = first
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(last - first)) else { throw ReferenceAudioError.decodeFailed }
        try file.read(into: buffer, frameCount: UInt32(last - first))
        guard Int64(buffer.frameLength) == last - first, let samples = buffer.floatChannelData else { throw ReferenceAudioError.decodeFailed }
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: importURL(id).path)
        return Array(UnsafeBufferPointer(start: samples[0], count: Int(buffer.frameLength)))
    }
    private struct Decoded { let rate: Double; let channels: Int }
    private func decodeNative(_ url: URL, writer: StreamingReferenceWAV) throws -> Decoded {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard source.sampleRate > 0, source.channelCount > 0, source.channelCount <= 32 else { throw ReferenceAudioError.decodeFailed }
        guard Double(file.length) / source.sampleRate <= 600 else { throw ReferenceAudioError.sourceTooLong }
        try convert(source: source, writer: writer) { requested in
            guard file.framePosition < file.length else { return nil }
            guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: requested) else { throw ReferenceAudioError.decodeFailed }
            try file.read(into: input, frameCount: requested)
            return input.frameLength == 0 ? nil : input
        }
        return Decoded(rate: source.sampleRate, channels: Int(source.channelCount))
    }
    private func decodeOpus(_ url: URL, writer: StreamingReferenceWAV) throws -> Decoded {
            var total: Int64 = 0, channels: Int32 = 0
            guard let decoder = url.path.withCString({ qwen_opus_open_file($0, &total, &channels) }) else { throw ReferenceAudioError.decodeFailed }
            defer { qwen_opus_close(decoder) }
            guard total > 0, total <= 48000 * 600 else { throw ReferenceAudioError.sourceTooLong }
            guard qwen_opus_seek(decoder, 0) == 0 else { throw ReferenceAudioError.decodeFailed }
            var stereo = [Float](repeating: 0, count: 8192 * 2)
            var readFrames: Int64 = 0
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            try convert(source: format, writer: writer) { requested in
                let count = qwen_opus_read(decoder, &stereo, Int32(requested * 2))
                guard count >= 0 else { throw ReferenceAudioError.decodeFailed }
                if count == 0 { return nil }
                let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count))!
                input.frameLength = UInt32(count)
                for i in 0..<Int(count) {
                    let sample = (stereo[i * 2] + stereo[i * 2 + 1]) / 2
                    guard sample.isFinite else { throw ReferenceAudioError.decodeFailed }
                    input.floatChannelData![0][i] = sample
                }
                readFrames += Int64(count)
                guard readFrames <= total else { throw ReferenceAudioError.decodeFailed }
                return input
            }
            guard readFrames == total else { throw ReferenceAudioError.decodeFailed }
            return Decoded(rate: 48000, channels: Int(channels))
    }
    private func convert(source: AVAudioFormat, writer: StreamingReferenceWAV,
                         read: @escaping (AVAudioFrameCount) throws -> AVAudioPCMBuffer?) throws {
        let destination = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        guard let converter = AVAudioConverter(from: source, to: destination),
              let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: 8192) else { throw ReferenceAudioError.decodeFailed }
        var readError: Error?, emptyPasses = 0
        while true {
            let status: AVAudioConverterOutputStatus = try autoreleasepool {
                var conversionError: NSError?
                let result = converter.convert(to: output, error: &conversionError) { requested, state in
                    do {
                        guard let input = try read(min(requested, 8192)) else { state.pointee = .endOfStream; return nil }
                        state.pointee = .haveData; return input
                    } catch { readError = error; state.pointee = .endOfStream; return nil }
                }
                if let readError { throw readError }
                guard conversionError == nil, result != .error else { throw ReferenceAudioError.decodeFailed }
                if output.frameLength > 0 { try writer.append(output) }
                return result
            }
            if output.frameLength > 0 { emptyPasses = 0 }
            else { emptyPasses += 1 }
            if status == .endOfStream { break }
            guard emptyPasses < 16 else { throw ReferenceAudioError.decodeFailed }
        }
    }
    private static func validateContainer(_ data: Data, ext: String) throws {
        func tag(_ start: Int, _ count: Int) -> String { data.count >= start + count ? String(data: data[start..<(start + count)], encoding: .ascii) ?? "" : "" }
        let valid: Bool
        switch ext {
        case "wav": valid = tag(0, 4) == "RIFF" && tag(8, 4) == "WAVE"
        case "mp3": valid = tag(0, 3) == "ID3" || (data.count >= 2 && data[0] == 255 && data[1] & 0xE0 == 0xE0)
        case "m4a": valid = tag(4, 4) == "ftyp"
        case "ogg": valid = tag(0, 4) == "OggS" && data.prefix(512).range(of: Data("OpusHead".utf8)) != nil
        default: valid = false
        }
        guard valid else { throw ReferenceAudioError.containerMismatch }
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func wav(_ samples: [Float], rate: Int) -> Data {
        var data = Data()
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(samples.count * 2 + 36)); data.append(contentsOf: "WAVEfmt ".utf8)
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(samples.count * 2))
        for value in samples { u16(UInt16(bitPattern: Int16((max(-1, min(1, value)) * 32767).rounded()))) }
        return data
    }
}
