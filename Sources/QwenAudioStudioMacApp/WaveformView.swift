import SwiftUI

struct WaveformView: View {
    let peaks: [Float]
    var activeFraction: Double = 0
    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(peaks.indices, id: \.self) { index in
                    Capsule()
                        .fill(Double(index) / Double(max(1, peaks.count)) <= activeFraction ? StudioPalette.green : StudioPalette.green.opacity(0.23))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(2, geo.size.height * CGFloat(peaks[index])))
                }
            }
            .frame(height: geo.size.height)
            .accessibilityLabel("音频波形")
        }
    }
}
