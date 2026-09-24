import SwiftUI
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

/// Presented by the durable AppState wiring in Task 9. The current disabled
/// CreationScreen button must stay disabled until that state exists.
struct GenerationSheet: View {
    let plan: GenerationPlan
    let directoryName: String
    let service: GenerationService
    let onConfirm: (String, String) -> Void
    let onCancel: () -> Void
    @State private var chargeAcknowledged = false
    @State private var confirmation = GenerationConfirmationController()

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("确认生成").font(.title2.weight(.semibold))
            Text("请核对最终发送内容。确认后将发起 \(plan.callCount) 次可能收费的模型请求。")
            LabeledContent("输出文件夹", value: directoryName)
            LabeledContent("候选 Seed", value: plan.seeds.map(String.init).joined(separator: "、"))
            if !plan.submission.references.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("本次上传的参考音频").font(.headline)
                    ForEach(Array(plan.submission.references.enumerated()), id: \.element.id) { index, reference in
                        Text("@voice\(index + 1) · \(reference.fileName) · \(reference.duration.formatted(.number.precision(.fractionLength(1)))) 秒")
                    }
                }
            }
            Text("最终编译 Prompt").font(.headline)
            ScrollView {
                Text(plan.prompt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 190)
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            Toggle("我已核对以上内容，了解每个候选可能产生费用", isOn: $chargeAcknowledged)
            if let error = confirmation.errorMessage { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("取消") {
                    confirmation.cancel()
                    onCancel()
                }
                Button("确认并生成") {
                    confirmation.begin(confirm: { try await service.confirm(plan) },
                        revoke: { await service.revokeAuthorization($0) },
                        onConfirmed: { authorization in
                            onConfirm(authorization.confirmationHash, authorization.clientRequestID)
                        })
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!chargeAcknowledged || confirmation.isConfirming)
            }
        }
        .padding(22)
        .frame(width: 620)
        .onDisappear { confirmation.disappear() }
    }
}
