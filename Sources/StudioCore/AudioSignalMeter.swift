import Foundation

public enum AudioQualityHint: String, Codable, Sendable { case silence, lowVolume, clipping }
public struct AudioSignalQuality: Codable, Sendable {
    public let rms: Double
    public let peak: Double
    public let hints: [AudioQualityHint]
}
public enum AudioSignalMeter {
    public static func measure(_ samples: [Float]) -> AudioSignalQuality {
        guard !samples.isEmpty else { return AudioSignalQuality(rms: 0, peak: 0, hints: [.silence]) }
        var sum = 0.0, peak = 0.0
        var clipped = 0
        for sample in samples {
            let value = sample.isFinite ? Double(sample) : 0
            sum += value * value; peak = max(peak, abs(value))
            if abs(value) >= 0.999 { clipped += 1 }
        }
        let rms = sqrt(sum / Double(samples.count))
        var hints: [AudioQualityHint] = []
        if peak < 0.0001 { hints.append(.silence) }
        else if rms < 0.01 { hints.append(.lowVolume) }
        if Double(clipped) / Double(samples.count) >= 0.001 { hints.append(.clipping) }
        return AudioSignalQuality(rms: rms, peak: peak, hints: hints)
    }
}
