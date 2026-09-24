import Foundation
import Darwin
import StudioCore

/// Isolated process high-water measurement; never initializes a live user store.
enum NativeReferenceMemoryQA {
    static func run(root: URL) -> Never {
        let canonical = root.resolvingSymlinksInPath()
        guard canonical.deletingLastPathComponent() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
              UUID(uuidString: canonical.lastPathComponent) != nil else { exit(65) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) { exit(124) }
        Task {
            do {
                let store = try StudioStore(dataRoot: canonical.appendingPathComponent("metadata"))
                let service = try ReferenceAudioService(root: canonical.appendingPathComponent("audio"), store: store)
                let source = try await service.importSource(url: canonical.appendingPathComponent("ten-minute-tone.ogg"))
                let tail = try await service.preview(importID: source.id, start: 594, end: 600)
                guard abs(source.duration - 600) < 0.001, tail.duration == 6, tail.quality.rms > 0.01 else { exit(1) }
                var previous: Int16 = 0, crossings = 0
                for offset in stride(from: 44, to: tail.data.count, by: 2) {
                    let sample = Int16(bitPattern: UInt16(tail.data[offset]) | (UInt16(tail.data[offset + 1]) << 8))
                    if previous <= 0, sample > 0 { crossings += 1 }
                    previous = sample
                }
                let frequency = Double(crossings) / tail.duration
                guard (870...890).contains(frequency) else { exit(1) }
                var usage = rusage()
                guard getrusage(RUSAGE_SELF, &usage) == 0 else { exit(1) }
                let peak = usage.ru_maxrss // Darwin reports bytes, unlike Linux's KiB.
                let result = "source=600.000s; tail=594...600s; tailDuration=6.000s; tailHz=\(frequency); peakRSSBytes=\(peak); limitBytes=167772160\n"
                try result.write(to: canonical.appendingPathComponent("reference-memory-checks.txt"), atomically: true, encoding: .utf8)
                print(result, terminator: "")
                try await store.close()
                exit(peak <= 160 * 1024 * 1024 ? 0 : 1)
            } catch { print("reference memory QA failed"); exit(1) }
        }
        dispatchMain()
    }
}
