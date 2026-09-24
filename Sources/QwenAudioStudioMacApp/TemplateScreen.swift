import SwiftUI
import StudioCore

struct TemplateScreen: View {
    @State private var selectedID = ProcessInfo.processInfo.arguments.contains("--capture-template=2") ? 2 : 1

    private let categories = ["全部", "播客", "广告", "有声书", "广播剧", "游戏配音", "旁白", "自定义"]
    private let previews = ShellPreviewTemplate.samples

    private var selectedPreview: ShellPreviewTemplate {
        ShellPreviewTemplate.sample(id: selectedID) ?? previews[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("从一个灵感开始")
                        .font(StudioTypography.serif(32))
                    Text("模板数据将在下一阶段接入；这里展示布局样例。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("自建模板") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(categories, id: \.self) { category in
                        Text(category)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(category == "全部" ? StudioPalette.greenSoft : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(category == "全部" ? StudioPalette.green : .primary)
                    }
                }
            }

            HStack(spacing: 10) {
                Label("搜索场景、标题或标签 · 后续接入", systemImage: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 27)
                    .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioPalette.stroke))
                    .frame(maxWidth: 440)
                Text("展示样例 · 3 个场景")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(previews) { item in
                            card(item)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                previewPane
                    .frame(width: 310)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(26)
        .background(StudioPalette.background)
        .navigationTitle("灵感模板")
    }

    private func card(_ item: ShellPreviewTemplate) -> some View {
        Button {
            selectedID = item.id
        } label: {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(item.mode.title)
                    Spacer()
                    Text(String(format: "%02d", item.id))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                Text(item.title)
                    .font(StudioTypography.serif(21))
                    .foregroundStyle(.primary)
                Text(item.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Label(item.suggestedDuration, systemImage: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 183, alignment: .leading)
            .background(StudioPalette.surface,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(selectedID == item.id ? StudioPalette.green : StudioPalette.stroke,
                        lineWidth: selectedID == item.id ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("脚本预览 · 样例")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(selectedPreview.title)
                .font(StudioTypography.serif(25))
            Text(selectedPreview.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Divider()
            Text(selectedPreview.script)
                .font(StudioTypography.serif(15))
                .lineSpacing(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            Button("应用到创作台") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .frame(maxWidth: .infinity)
            Text("完整模板与变量预览将在下一阶段接入")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(18)
        .background(StudioPalette.surface,
                    in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(StudioPalette.stroke))
    }
}
