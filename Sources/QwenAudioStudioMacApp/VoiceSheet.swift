import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import StudioCore

/// Reference controls share the single result player and never own a second output.
@MainActor @Observable final class ReferencePlayback {
    static let shared = ReferencePlayback()
    enum State: Equatable { case stopped, source, selection, library }
    private let transport: AudioPlaybackController
    init(transport: AudioPlaybackController = .shared) { self.transport = transport }
    private var previewKind: State = .stopped
    var state: State { transport.isPreview && transport.state == .playing ? previewKind : .stopped }
    var volume: Float {
        get { transport.volume }
        set { transport.volume = newValue }
    }
    func play(_ data: Data, state: State) throws {
        try transport.playPreview(data: data)
        previewKind = state
    }
    func stop() {
        if transport.isPreview { transport.stop() }
        previewKind = .stopped
    }
}

@MainActor @Observable final class VoiceSheetController {
    let service: ReferenceAudioService
    var imported: ImportedReference? { didSet { if oldValue?.id != imported?.id { selectionChanged() } } }
    var start = 0.0 { didSet { if oldValue != start { selectionChanged() } } }
    var end = 0.0 { didSet { if oldValue != end { selectionChanged() } } }
    var name = ""
    var persistent = false
    var busy = false
    var message: String?
    var quality: AudioSignalQuality?
    var library: [ReferenceSnapshot] = []
    private var warnedSelection: String?
    var selectionKey: String { "\(imported?.id ?? ""):\(start):\(end)" }
    var requiresQualityAcknowledgement: Bool { warnedSelection == selectionKey }
    init(service: ReferenceAudioService) { self.service = service }
    var selectionValid: Bool {
        guard let imported else { return false }
        return start.isFinite && end.isFinite && start >= 0 && end > start && end <= imported.duration && end - start <= 30
    }
    static func nextSlot(fields: DraftFields) -> Int? {
        (1...3).first { slot in
            !fields.referenceBindings.contains(where: { $0.slot == slot }) && !fields.prompt.contains("@voice\(slot)")
        }
    }
    func loadLibrary() async {
        do { _ = try await service.cleanup(); library = try await service.library() }
        catch { message = "本地音色暂不可用，请重试。" }
    }
    func choose() async {
        let panel = NSOpenPanel()
        panel.title = "导入参考音频"; panel.prompt = "导入"
        panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio, UTType(filenameExtension: "ogg") ?? .audio]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        let response = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
        guard response == .OK, let url = panel.url else { return }
        await importURL(url)
    }
    func importURL(_ url: URL) async {
        busy = true; message = nil; ReferencePlayback.shared.stop()
        defer { busy = false }
        do {
            let source = try await service.importSource(url: url)
            imported = source; start = 0; end = source.duration
            name = url.deletingPathExtension().lastPathComponent; quality = source.quality
        } catch { message = Self.explain(error) }
    }
    func preview(source: Bool) async {
        guard let imported else { return }
        do {
            if source { try ReferencePlayback.shared.play(await service.sourcePreview(importID: imported.id), state: .source) }
            else {
                let preview = try await service.preview(importID: imported.id, start: start, end: end)
                quality = preview.quality
                try ReferencePlayback.shared.play(preview.data, state: .selection)
            }
            message = nil
        } catch { message = Self.explain(error) }
    }
    private func selectionChanged() {
        quality = nil; warnedSelection = nil; message = nil
        ReferencePlayback.shared.stop()
    }
    func analyzeSelection() async {
        guard selectionValid, let imported else { quality = nil; return }
        let key = selectionKey, start = start, end = end
        do {
            let preview = try await service.preview(importID: imported.id, start: start, end: end)
            guard key == selectionKey, !Task.isCancelled else { return }
            quality = preview.quality
        } catch { if key == selectionKey { message = Self.explain(error) } }
    }
    func prepare(allowQualityWarnings: Bool = false) async -> PreparedReference? {
        guard selectionValid, let imported, !busy else { return nil }
        let key = selectionKey, start = start, end = end, name = name, persistent = persistent
        busy = true; defer { busy = false }
        do {
            let preview = try await service.preview(importID: imported.id, start: start, end: end)
            guard key == selectionKey else { return nil }
            quality = preview.quality
            let needsWarning = preview.quality.hints.contains(.silence) || preview.quality.hints.contains(.clipping)
            if needsWarning && !(allowQualityWarnings && warnedSelection == key) {
                warnedSelection = key
                message = "当前选区检测到\(preview.quality.hints.contains(.silence) ? "静音" : "疑似削波失真")。可重新选择，或点击“仍然使用此片段”。"
                return nil
            }
            message = nil
            return try await service.prepare(importID: imported.id, start: start, end: end, persistent: persistent, name: name)
        }
        catch { message = Self.explain(error); return nil }
    }
    static func explain(_ error: Error) -> String {
        switch error as? ReferenceAudioError {
        case .sourceTooLarge: "源文件超过 50 MiB，请先选择较小的音频。"
        case .sourceTooLong: "源音频超过 10 分钟，请先选择较短的音频。"
        case .invalidSelection: "请手动选择大于 0 秒、最多 30 秒的片段。"
        case .containerMismatch: "文件扩展名与容器不一致，或文件格式不受支持。"
        default: "无法读取或播放音频。请检查文件是否完整、可访问，并重新导入。"
        }
    }
}

struct VoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var controller: VoiceSheetController
    let draft: DraftController
    private var slot: Int? { VoiceSheetController.nextSlot(fields: draft.fields) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("参考音色").font(StudioTypography.serif(25))
                    Text("手动选择片段 · 原文件保持完整").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("本地音色库", systemImage: "person.wave.2").font(.headline)
                    if controller.library.isEmpty { Text("主动保存的音色会显示在这里。") .font(.caption).foregroundStyle(.secondary) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(controller.library) { voice in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(voice.fileName).lineLimit(2)
                                    Text("\(voice.duration, specifier: "%.2f") 秒").font(.caption).foregroundStyle(.secondary)
                                    HStack {
                                        Button("试听") { Task {
                                            do { let item = try await controller.service.prepared(referenceID: voice.id); try ReferencePlayback.shared.play(item.data, state: .library) }
                                            catch { controller.message = VoiceSheetController.explain(error) }
                                        } }
                                        Button("使用") { Task {
                                            do { bind(try await controller.service.prepared(referenceID: voice.id)) }
                                            catch { controller.message = VoiceSheetController.explain(error) }
                                        } }.disabled(slot == nil)
                                    }
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(StudioPalette.background, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }.frame(maxHeight: .infinity)
                    Text("当前绑定").font(.headline)
                    ForEach(draft.fields.referenceBindings, id: \.referenceID) { binding in
                        HStack {
                            Text("@voice\(binding.slot) · \(binding.alias)").lineLimit(1)
                            Spacer()
                            Button { draft.change { $0.referenceBindings.removeAll { $0.referenceID == binding.referenceID } } } label: { Image(systemName: "minus.circle") }
                                .help("移除绑定；脚本中的原槽位将提示修复")
                        }.font(.caption)
                    }
                }.frame(width: 205)
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("导入与裁剪", systemImage: "waveform").font(.headline)
                        Spacer()
                        Button("选择音频…") { Task { await controller.choose() } }.disabled(controller.busy)
                    }
                    Text("WAV / MP3 / M4A / OGG Opus · ≤ 50 MiB · ≤ 10 分钟")
                        .font(.caption).foregroundStyle(.secondary)
                    if let imported = controller.imported {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(imported.fileName).fontWeight(.medium).lineLimit(2)
                            Text("\(imported.duration, specifier: "%.2f") 秒  ·  \(Int(imported.sampleRate)) Hz  ·  \(imported.channels) 声道")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("试听完整源音频") { Task { await controller.preview(source: true) } }
                                Button("停止") { ReferencePlayback.shared.stop() }
                                    .disabled(ReferencePlayback.shared.state == .stopped)
                                Text(playbackTitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(StudioPalette.background, in: RoundedRectangle(cornerRadius: 10))
                        HStack(spacing: 18) {
                            timeField("开始（秒）", value: $controller.start)
                            timeField("结束（秒）", value: $controller.end)
                        }
                        trimSlider("片段开始", value: $controller.start, duration: imported.duration)
                        trimSlider("片段结束", value: $controller.end, duration: imported.duration)
                        HStack {
                            Text("选区 \(max(0, controller.end - controller.start), specifier: "%.2f") 秒 / 最多 30 秒")
                                .font(.callout).foregroundStyle(controller.selectionValid ? Color.primary : .orange)
                            Spacer()
                            Button("试听选区") { Task { await controller.preview(source: false) } }.disabled(!controller.selectionValid)
                        }
                        if let quality = controller.quality {
                            Text(quality.hints.isEmpty ? "音量检测正常；请试听确认发音与背景噪声。" : quality.hints.map(hint).joined(separator: " · "))
                                .font(.caption).foregroundStyle(quality.hints.isEmpty ? Color.secondary : .orange)
                        }
                        TextField("音色名称", text: $controller.name).textFieldStyle(.roundedBorder)
                        Toggle("保存到本地音色库", isOn: $controller.persistent)
                        Text("默认暂存；空闲一小时且没有任务使用时可清理。每批生成前会单独确认上传文件与时长。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        ContentUnavailableView("选择一段参考音频", systemImage: "waveform.badge.plus", description: Text("在本机解码与试听，手动确定起止点。"))
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let message = controller.message { Text(message).font(.caption).foregroundStyle(controller.requiresQualityAcknowledgement ? Color.orange : .red) }
            HStack {
                Text(slot.map { "新片段将绑定 @voice\($0)" } ?? "暂无空闲槽位，请先处理脚本中已有的 @voice1–3。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if controller.busy { ProgressView().controlSize(.small) }
                Button(controller.requiresQualityAcknowledgement ? "仍然使用此片段" : (controller.persistent ? "保存并使用片段" : "暂存并使用片段")) { Task {
                    if let prepared = await controller.prepare(allowQualityWarnings: controller.requiresQualityAcknowledgement) { bind(prepared) }
                } }.buttonStyle(.borderedProminent).tint(StudioPalette.green)
                    .disabled(!controller.selectionValid || controller.busy || slot == nil)
            }
        }
        .padding(24).frame(width: 850, height: 600).background(StudioPalette.surface)
        .task { await controller.loadLibrary() }
        .task(id: controller.selectionKey) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await controller.analyzeSelection()
        }
        .onDisappear { ReferencePlayback.shared.stop() }
    }
    private var playbackTitle: String {
        switch ReferencePlayback.shared.state { case .stopped: ""; case .source: "正在试听源音频"; case .selection: "正在试听选区"; case .library: "正在试听本地音色" }
    }
    private func timeField(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number.precision(.fractionLength(2))).textFieldStyle(.roundedBorder).monospacedDigit()
        }
    }
    private func trimSlider(_ label: String, value: Binding<Double>, duration: Double) -> some View {
        HStack {
            Text(label).font(.callout).frame(width: 60, alignment: .leading)
            ReferenceTrimSlider(value: value.wrappedValue, maximum: duration, label: label,
                                onChange: { value.wrappedValue = $0 }).frame(height: 22)
        }
    }
    private func hint(_ value: AudioQualityHint) -> String {
        switch value { case .silence: "检测到静音，建议重选片段"; case .lowVolume: "音量偏低，请试听确认"; case .clipping: "可能存在削波失真，请试听确认" }
    }
    private func bind(_ prepared: PreparedReference) {
        if let existing = draft.fields.referenceBindings.first(where: { $0.referenceID == prepared.snapshot.id }) {
            controller.message = "此音色已绑定 @voice\(existing.slot)。"; return
        }
        guard let slot else { return }
        draft.change { $0.referenceBindings.append(.init(referenceID: prepared.snapshot.id, alias: prepared.snapshot.fileName, slot: slot)) }
        dismiss()
    }
}

/// Keep AppKit's native keyboard, focus, accessibility and hit-testing behavior,
/// while drawing a thin track without thousands of discrete tick marks.
private struct ReferenceTrimSlider: NSViewRepresentable {
    let value: Double
    let maximum: Double
    let label: String
    let onChange: (Double) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.cell = ReferenceTrimSliderCell()
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.onChange = onChange
        slider.minValue = 0; slider.maxValue = max(0.001, maximum)
        slider.doubleValue = value
        slider.setAccessibilityLabel(label)
    }
    @MainActor final class Coordinator: NSObject {
        var onChange: (Double) -> Void
        init(onChange: @escaping (Double) -> Void) { self.onChange = onChange }
        @objc func changed(_ slider: NSSlider) {
            onChange(min(slider.maxValue, (slider.doubleValue * 100).rounded() / 100))
        }
    }
}

private final class ReferenceTrimSliderCell: NSSliderCell {
    private var accent: NSColor {
        if controlView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(red: 0.54, green: 0.78, blue: 0.69, alpha: 1)
        }
        return NSColor(red: 0.10, green: 0.38, blue: 0.33, alpha: 1)
    }
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: knobRect(flipped: flipped).midY - 2, width: rect.width, height: 4)
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let fraction = maxValue > minValue ? min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))) : 0
        let progress = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        accent.setFill()
        NSBezierPath(roundedRect: progress, xRadius: 2, yRadius: 2).fill()
    }
    override func drawKnob(_ knobRect: NSRect) {
        let circle = NSRect(x: knobRect.midX - 6, y: knobRect.midY - 6, width: 12, height: 12)
        accent.setFill()
        NSBezierPath(ovalIn: circle).fill()
    }
}
