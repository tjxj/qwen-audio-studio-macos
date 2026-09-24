import Foundation

public enum AudioQualityHint: String, Codable, Sendable { case silence, lowVolume, clipping }
public struct AudioSignalQuality: Codable, Sendable {
    public let rms: Double
    public let peak: Double
    public let hints: [AudioQualityHint]
}
public enum AudioSignalMeter {
    public static func measure(_ samples: [Float]) -> AudioSignalQuality {
        var accumulator = AudioSignalAccumulator()
        for sample in samples { accumulator.append(sample) }
        return accumulator.quality
    }
}

struct AudioSignalAccumulator {
    private var sum = 0.0, peak = 0.0
    private var count = 0, clipped = 0
    mutating func append(_ sample: Float) {
            let value = sample.isFinite ? Double(sample) : 0
            sum += value * value; peak = max(peak, abs(value)); count += 1
            if abs(value) >= 0.999 { clipped += 1 }
    }
    var quality: AudioSignalQuality {
        guard count > 0 else { return AudioSignalQuality(rms: 0, peak: 0, hints: [.silence]) }
        let rms = sqrt(sum / Double(count))
        var hints: [AudioQualityHint] = []
        if peak < 0.0001 { hints.append(.silence) }
        else if rms < 0.01 { hints.append(.lowVolume) }
        if Double(clipped) / Double(count) >= 0.001 { hints.append(.clipping) }
        return AudioSignalQuality(rms: rms, peak: peak, hints: hints)
    }
}
