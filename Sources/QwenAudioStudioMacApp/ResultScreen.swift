import SwiftUI
import Foundation
import Observation
import StudioCore

struct ResultCandidate: Identifiable, Sendable {
    let id: String
    let number: Int
    let state: JobState
    let assetID: String?
    var isFinal = false
}

enum ResultValidationStatus: Equatable { case checking, ready, unavailable, noAudio }

struct ResultRow: Identifiable {
    let candidate: ResultCandidate
    var id: String { candidate.id }
    var status: ResultValidationStatus = .checking
    var duration: Double?
    var sampleRate: Double?
    var hash: String?
    var waveform: [Float] = []
    var playable: Bool { status == .ready }
}

@MainActor @Observable final class ResultScreenController {
    private(set) var rows: [ResultRow]
    private let loader: (String) async throws -> DecodedAudio
    private let cache = WaveformCache()
    var selectedID: String?
    var compareID: String?
    private var compareAID: String?
    var message: String?
    var loopEnabled = false
    init(candidates: [ResultCandidate], loader: @escaping (String) async throws -> DecodedAudio) {
        rows = candidates.map { ResultRow(candidate: $0, status: $0.assetID == nil ? .noAudio : .checking) }
        self.loader = loader
        selectedID = candidates.first?.id
    }
    convenience init(candidates: [ResultCandidate], assets: GeneratedAssetStore) {
        self.init(candidates: candidates, loader: { id in try await assets.decodeRegisteredAudio(id) })
        AudioPlaybackController.shared.configure(assets: assets)
    }
    func validate() async {
        for index in rows.indices {
            guard let assetID = rows[index].candidate.assetID else { continue }
            do {
                let audio = try await loader(assetID)
                rows[index].duration = audio.duration
                rows[index].sampleRate = audio.sampleRate
                rows[index].hash = audio.contentHash
                rows[index].waveform = cache.envelope(for: audio, bins: 96)
                rows[index].status = .ready
            } catch { rows[index].status = .unavailable }
        }
    }
    var selected: ResultRow? { rows.first { $0.id == selectedID } }
    var comparison: ResultRow? { rows.first { $0.id == compareID } }
    func select(_ id: String, player: AudioPlaybackController) {
        guard rows.contains(where: { $0.id == id }) else { return }
        if selectedID != id {
            player.stop()
            compareID = nil
            compareAID = nil
            message = nil
            loopEnabled = false
        }
        selectedID = id
    }
    enum ComparisonSide { case a, b }
    func beginComparison(a: String, b: String) {
        compareAID = a; compareID = b; selectedID = a
    }
    func selectComparisonSide(_ side: ComparisonSide) {
        selectedID = side == .a ? compareAID : compareID
    }
    func setLoop(enabled: Bool, start: Double, end: Double, player: AudioPlaybackController) {
        if enabled {
            do {
                try player.setLoop(start: start, end: end)
                loopEnabled = true; message = nil
            } catch {
                player.clearLoop()
                loopEnabled = false
                message = "循环选区需至少 0.5 秒，且在当前版本范围内。"
            }
        } else {
            player.clearLoop(); loopEnabled = false
        }
    }
    func play(_ id: String, player: AudioPlaybackController) async {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].playable,
              let assetID = rows[index].candidate.assetID else { return }
        do {
            if player.activeAssetID == assetID && player.state == .playing { player.pause() }
            else if player.activeAssetID == assetID && player.state == .paused { try player.resume() }
            else { try await player.play(assetID: assetID) }
            message = nil
        } catch {
            if case AudioPlaybackError.superseded = error { return }
            if case AudioPlaybackError.outputUnavailable = error {
                message = "音频输出暂不可用，请检查设备后重试。"
            } else {
                rows[index].status = .unavailable
                rows[index].waveform = []
                message = "此版本无法播放，请检查原文件和目录授权。"
            }
        }
    }
    func compare(a: String, b: String, player: AudioPlaybackController) async {
        guard let aRow = rows.first(where: { $0.id == a && $0.playable }),
              let bRow = rows.first(where: { $0.id == b && $0.playable }),
              let aAsset = aRow.candidate.assetID, let bAsset = bRow.candidate.assetID else { return }
        loopEnabled = false
        do {
            try await player.compare(assetA: aAsset, assetB: bAsset)
            try player.switchToA()
            beginComparison(a: a, b: b)
            message = nil
        } catch {
            if case AudioPlaybackError.superseded = error { return }
            if case AudioPlaybackError.outputUnavailable = error {
                message = "音频输出暂不可用，请检查设备后重试 A/B。"
            } else {
                await validate()
                message = "比较版本的文件无法读取或解码，请检查目录授权。"
            }
        }
    }
}

struct ResultScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @State var controller: ResultScreenController
    @State private var player = AudioPlaybackController.shared
    @State private var selectedPosition = 0.0
    @State private var isSeeking = false
    @State private var loopStart = 0.0
    @State private var loopEnd = 0.5
    private var accent: Color { colorScheme == .dark ? Color(red: 0.50, green: 0.79, blue: 0.69) : StudioPalette.green }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("作品结果").font(StudioTypography.serif(30))
                    Text("逐个试听，保持同一时间点比较不同版本。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(controller.rows.count) 个版本")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("生成版本").font(.headline)
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(controller.rows) { row in
                                Button { controller.select(row.id, player: player); selectedPosition = 0 } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: row.playable ? "waveform" : "waveform.slash")
                                            .frame(width: 20)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("版本 \(row.candidate.number)").fontWeight(.medium)
                                            Text(status(row)).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if row.candidate.isFinal { Text("最终").font(.caption.bold()).foregroundStyle(accent) }
                                        if controller.compareID == row.id { Text("B").font(.caption.bold()) }
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(controller.selectedID == row.id
                                                ? StudioPalette.green.opacity(colorScheme == .dark ? 0.25 : 0.10)
                                                : StudioPalette.surface,
                                                in: RoundedRectangle(cornerRadius: 9))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(width: 235)
                VStack(alignment: .leading, spacing: 18) {
                    if let row = controller.selected {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("版本 \(row.candidate.number)").font(StudioTypography.serif(23))
                                    if row.candidate.isFinal { Label("最终版本", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(accent) }
                                }
                                Text(status(row)).font(.caption).foregroundStyle(row.playable ? Color.secondary : Color.orange)
                            }
                            Spacer()
                            if let duration = row.duration { Text(duration.formatted(.number.precision(.fractionLength(2))) + " s").monospacedDigit().foregroundStyle(.secondary) }
                        }
                        WaveformView(peaks: row.waveform, activeFraction: row.duration.map { player.position / $0 } ?? 0)
                            .frame(minHeight: 160, maxHeight: .infinity)
                            .padding(.horizontal, 4)
                            .background(StudioPalette.green.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                        Slider(value: $selectedPosition, in: 0...max(0.001, row.duration ?? 0.001)) { editing in
                            isSeeking = editing
                            if !editing { try? player.seek(seconds: selectedPosition) }
                        }
                        .disabled(!row.playable)
                        .accessibilityLabel("播放位置")
                        HStack {
                            Button { Task { await play(row) } } label: {
                                let playingThis = player.state == .playing && player.activeAssetID == row.candidate.assetID
                                Label(playingThis ? "暂停" : "播放", systemImage: playingThis ? "pause.fill" : "play.fill")
                            }
                                .buttonStyle(.borderedProminent).tint(StudioPalette.green).disabled(!row.playable)
                            Button { try? player.backTenSeconds(); selectedPosition = player.position } label: { Label("后退 10 秒", systemImage: "gobackward.10") }
                                .disabled(!row.playable)
                            Button("A/B 同位置") { Task { await compare(row) } }
                                .disabled(!row.playable || controller.rows.filter(\.playable).count < 2)
                            if controller.compareID != nil {
                                Button("A") {
                                    do { try player.switchToA(); controller.selectComparisonSide(.a); selectedPosition = player.position }
                                    catch { controller.message = "无法切换到 A 版本。" }
                                }
                                Button("B") {
                                    do { try player.switchToB(); controller.selectComparisonSide(.b); selectedPosition = player.position }
                                    catch { controller.message = "无法切换到 B 版本。" }
                                }
                            }
                            Spacer()
                        }
                        HStack(spacing: 10) {
                            Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                            Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                                .frame(width: 145).accessibilityLabel("音量")
                            Divider().frame(height: 19)
                            Toggle("选区循环", isOn: Binding(get: { controller.loopEnabled },
                                set: { controller.setLoop(enabled: $0, start: loopStart, end: loopEnd, player: player) }))
                                .toggleStyle(.checkbox)
                            TextField("起点", value: $loopStart, format: .number.precision(.fractionLength(2))).frame(width: 58)
                            Text("—")
                            TextField("终点", value: $loopEnd, format: .number.precision(.fractionLength(2))).frame(width: 58)
                            Text("秒").foregroundStyle(.secondary)
                            Button("应用") { controller.setLoop(enabled: true, start: loopStart, end: loopEnd, player: player) }
                                .disabled(!row.playable)
                        }.font(.caption)
                        if let message = controller.message { Text(message).font(.caption).foregroundStyle(.orange) }
                        Divider()
                        HStack(spacing: 22) {
                            metric("实际时长", value: row.duration.map { String(format: "%.2f 秒", $0) } ?? "—")
                            metric("解码采样率", value: row.sampleRate.map { "\(Int($0)) Hz" } ?? "—")
                            metric("内容校验", value: row.hash.map { String($0.prefix(12)).uppercased() } ?? "—")
                            Spacer()
                            Label("本机解码验收", systemImage: row.playable ? "checkmark.seal" : "exclamationmark.triangle")
                                .foregroundStyle(row.playable ? accent : Color.orange)
                                .font(.caption)
                        }
                    } else { ContentUnavailableView("暂无版本", systemImage: "waveform") }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 13))
            }
            .frame(maxHeight: .infinity)
        }
        .padding(24)
        .background(StudioPalette.background)
        .task {
            await controller.validate()
            while !Task.isCancelled {
                if !isSeeking && player.state == .playing && player.activeAssetID == controller.selected?.candidate.assetID {
                    selectedPosition = player.position
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .onDisappear { player.stop() }
    }
    private func status(_ row: ResultRow) -> String {
        switch row.status {
        case .checking: "正在验证音频…"
        case .ready: "已验证 · 可播放 PCM"
        case .unavailable: "文件丢失或音频无法解码"
        case .noAudio: row.candidate.state == .failed ? "生成失败 · 无音频" : "暂无音频"
        }
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.72) : Color.secondary)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }
    private func play(_ row: ResultRow) async {
        await controller.play(row.id, player: player)
        selectedPosition = player.position
    }
    private func compare(_ row: ResultRow) async {
        guard let bRow = controller.rows.first(where: { $0.id != row.id && $0.playable }) else { return }
        await controller.compare(a: row.id, b: bRow.id, player: player)
    }
}
