import SwiftUI

struct LibraryScreen: View {
    @State private var tab = 0
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("作品库")
                    .font(StudioTypography.serif(32))
                Text("每一次灵感，都有迹可循。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Picker("作品视图", selection: $tab) {
                Text("全部生成").tag(0)
                Text("项目").tag(1)
                Text("回收站").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 320)

            HStack(spacing: 12) {
                TextField("搜索作品、项目或文案…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 490)

                Picker("类型", selection: .constant("全部类型")) {
                    Text("全部类型").tag("全部类型")
                }
                .frame(width: 130)
                .disabled(true)

                Picker("状态", selection: .constant("全部状态")) {
                    Text("全部状态").tag("全部状态")
                }
                .frame(width: 130)
                .disabled(true)
                Spacer()
            }

            VStack(spacing: 18) {
                Image(systemName: tab == 2 ? "trash" : "square.stack.3d.up")
                    .font(.system(size: 36, weight: .ultraLight))
                    .foregroundStyle(StudioPalette.green)
                    .frame(width: 76, height: 76)
                    .background(StudioPalette.greenSoft, in: Circle())

                Text(tab == 2 ? "回收站是空的" : "还没有生成记录")
                    .font(StudioTypography.serif(22))
                Text("本地作品库将在数据存储接入后显示。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("界面预览 · 没有读取或修改旧版数据")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StudioPalette.surface,
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioPalette.stroke))
        }
        .padding(26)
        .background(StudioPalette.background)
        .navigationTitle("作品库")
    }
}
