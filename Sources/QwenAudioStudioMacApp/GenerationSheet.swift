import SwiftUI
import StudioCore

/// Presented by the durable AppState wiring in Task 9. The current disabled
/// CreationScreen button must stay disabled until that state exists.
struct GenerationSheet: View {
    let plan: GenerationPlan
    let directoryName: String
    let onConfirm: (String, String) -> Void
    let onCancel: () -> Void
    @State private var chargeAcknowledged = false

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
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("确认并生成") { onConfirm(plan.confirmationHash, plan.submission.clientRequestID) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!chargeAcknowledged)
            }
        }
        .padding(22)
        .frame(width: 620)
    }
}
