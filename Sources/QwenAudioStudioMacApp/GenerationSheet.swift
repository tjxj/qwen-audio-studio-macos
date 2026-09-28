import SwiftUI
import AppKit
import StudioCore
import Observation

@MainActor @Observable
final class GenerationConfirmationController {
    private var task: Task<Void, Never>?
    private var generation = 0
    private var active = true
    private(set) var isConfirming = false
    private(set) var errorMessage: String?

    @discardableResult func begin(
        confirm: @escaping @Sendable () async throws -> GenerationAuthorization,
        revoke: @escaping @Sendable (GenerationAuthorization) async -> Void,
        onConfirmed: @escaping @MainActor (GenerationAuthorization) -> Void
    ) -> Task<Void, Never> {
        guard active else { return Task {} }
        generation += 1
        let started = generation
        task?.cancel()
        isConfirming = true
        errorMessage = nil
        let work = Task { @MainActor in
            do {
                let authorization = try await confirm()
                guard active, started == generation, !Task.isCancelled else {
                    await revoke(authorization)
                    return
                }
                isConfirming = false
                task = nil
                onConfirmed(authorization)
            } catch {
                guard active, started == generation, !Task.isCancelled else { return }
                isConfirming = false
                task = nil
                errorMessage = "确认内容已变化，请重新预检。"
            }
        }
        task = work
        return work
    }

    func cancel() {
        active = false
        generation += 1
        task?.cancel()
        task = nil
        isConfirming = false
    }

    func disappear() { cancel() }
}

struct GenerationSheet: View {
    static func referenceDisplaySlot(referenceID: String, fields: DraftFields) -> Int? {
        fields.referenceBindings.first(where: { $0.referenceID == referenceID })?.slot
    }

    let plan: GenerationPlan?
    let directoryName: String
    let appState: AppState
    let onDismiss: () -> Void
    var onNavigateToLibrary: (() -> Void)? = nil

    @State private var chargeAcknowledged = false
    @State private var confirmation = GenerationConfirmationController()
    @State private var elapsedSeconds: Int = 0
    @State private var timer: Timer? = nil

    var body: some View {
        VStack(spacing: 0) {
            if appState.generationFinished {
                if !appState.generationResults.isEmpty {
                    successView
                } else {
                    failureView
                }
            } else if appState.submitting {
                progressView
            } else if let plan {
                confirmationView(plan)
            } else {
                progressView
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear {
            if appState.submitting {
                startTimer()
            }
        }
        .onDisappear {
            stopTimer()
            confirmation.disappear()
        }
    }

    // 1. 确认生成内容与费用
    private func confirmationView(_ plan: GenerationPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("确认生成全景声音频")
                .font(.title2.weight(.bold))

            Text("请核对最终发送内容。确认后将发起 \(plan.callCount) 次模型生成请求。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                LabeledContent("输出文件夹", value: directoryName)
                LabeledContent("候选 Seed", value: plan.seeds.map(String.init).joined(separator: "、"))
                LabeledContent("音频格式", value: "\(plan.submission.project.fields.params.format.uppercased()) · \(plan.submission.project.fields.params.sampleRate) Hz")
            }
            .font(.system(size: 12))
            .padding(12)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))

            if !plan.submission.references.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("本次上传的参考音频").font(.headline)
                    ForEach(plan.submission.references) { reference in
                        Text("@voice\(Self.referenceDisplaySlot(referenceID: reference.id, fields: plan.submission.project.fields) ?? 0) · \(reference.fileName) · \(reference.duration.formatted(.number.precision(.fractionLength(1)))) 秒")
                            .font(.system(size: 12))
                    }
                }
            }

            Text("最终编译 Prompt").font(.headline)
            ScrollView {
                Text(plan.prompt)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            .padding(10)
            .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioPalette.stroke))

            Toggle("我已核对以上内容，了解每个候选可能产生费用", isOn: $chargeAcknowledged)
                .font(.system(size: 12))

            if let error = confirmation.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("取消") {
                    confirmation.cancel()
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("确认并生成") {
                    startTimer()
                    confirmation.begin(confirm: { try await appState.generation.confirm(plan) },
                        revoke: { await appState.generation.revokeAuthorization($0) },
                        onConfirmed: { authorization in
                            appState.submit(plan: plan, hash: authorization.confirmationHash, requestID: authorization.clientRequestID)
                        })
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioPalette.green)
                .disabled(!chargeAcknowledged || confirmation.isConfirming)
            }
            .padding(.top, 4)
        }
    }

    // 2. 实时生成中进度条视图
    private var progressView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(StudioPalette.green.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "waveform")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(StudioPalette.green)
            }
            .padding(.top, 12)

            VStack(spacing: 8) {
                Text("正在生成全景声音频…")
                    .font(.title3.weight(.bold))

                Text(appState.activeGenerationStage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // 进度指示器
            VStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(StudioPalette.green)
                    .frame(maxWidth: 480)

                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(directoryName)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                    Spacer()

                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                        Text("已耗时 \(elapsedSeconds) 秒")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 480)
            }
            .padding(.vertical, 8)

            HStack(spacing: 12) {
                Button("在后台继续") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                if appState.activeBatchID != nil {
                    Button("取消未开始候选") {
                        Task { await appState.cancelRemaining() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                }
            }
            .padding(.bottom, 8)
        }
        .frame(minHeight: 340)
    }

    // 3. 生成成功交付视图（明确路径、试听、在 Finder 中显示）
    private var successView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(StudioPalette.green.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(StudioPalette.green)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("全景声音频生成成功！")
                        .font(.title2.weight(.bold))
                    Text("已成功下载并写入本地作品库与指定输出文件夹")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Divider().opacity(0.4)

            // 音频列表与即刻试听
            VStack(spacing: 12) {
                ForEach(appState.generationResults) { result in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.fileURL.lastPathComponent)
                                    .font(.system(size: 13, weight: .semibold))

                                Text("\(result.format.uppercased()) · \(result.sampleRate) Hz · \(result.duration.formatted(.number.precision(.fractionLength(1)))) 秒")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            // 试听播放按钮
                            Button {
                                Task {
                                    if appState.playback.activeAssetID == result.assetID && appState.playback.state == .playing {
                                        appState.playback.pause()
                                    } else if appState.playback.activeAssetID == result.assetID && appState.playback.state == .paused {
                                        try? appState.playback.resume()
                                    } else {
                                        do {
                                            try appState.playback.play(fileURL: result.fileURL, assetID: result.assetID)
                                        } catch {
                                            try? await appState.playback.play(assetID: result.assetID)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: appState.playback.activeAssetID == result.assetID && appState.playback.state == .playing
                                          ? "pause.fill" : "play.fill")
                                    Text(appState.playback.activeAssetID == result.assetID && appState.playback.state == .playing
                                         ? "暂停" : "试听")
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(StudioPalette.green)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(StudioPalette.green.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)

                            // 在 Finder 中显示
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([result.fileURL])
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder")
                                    Text("在 Finder 中显示")
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(StudioPalette.surface, in: Capsule())
                                .overlay(Capsule().stroke(StudioPalette.stroke))
                            }
                            .buttonStyle(.plain)
                        }

                        // 文件实际存储路径
                        HStack(spacing: 4) {
                            Text("本地存储位置：")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(result.fileURL.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(14)
                    .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioPalette.stroke))
                }
            }

            Divider().opacity(0.4)

            HStack {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(appState.generationResults.map(\.fileURL))
                } label: {
                    Label("打开文件所在文件夹", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 12))
                }

                Spacer()

                if let onNavigateToLibrary {
                    Button("查看作品库") {
                        appState.playback.stop()
                        onNavigateToLibrary()
                        onDismiss()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                }

                Button("完成") {
                    appState.playback.stop()
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioPalette.green)
            }
        }
    }

    // 4. 生成失败/中断详细视图
    private var failureView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("音频生成未完成")
                        .font(.title2.weight(.bold))
                    Text("模型服务未成功返回有效音频数据")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("错误详情：")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(appState.generationFailedMessage ?? appState.activeGenerationStage)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.2)))
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("排查建议：")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("1. 请前往「设置」核对百炼 API Key 是否有效，以及是否具备 qwen-audio-3.1-tts-next 权限。")
                Text("2. 核对 Workspace ID（业务空间 ID）是否填写正确。")
                Text("3. 检查网络连接是否正常，或在输出文件夹中重新授权目录。")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("关闭") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func startTimer() {
        elapsedSeconds = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                elapsedSeconds += 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
