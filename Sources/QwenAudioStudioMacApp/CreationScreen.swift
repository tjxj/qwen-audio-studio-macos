import SwiftUI
import StudioCore

struct CreationScreen: View {
    @State private var name = "雨夜里的慢生活"
    @State private var mode: CreationMode = .podcast
    @State private var script = "【场景】雨夜，窗边的一盏灯。\n\n【角色：讲述者】温和沉静，自然舒缓。\n\n【音效】细雨落在窗沿，轻柔、不盖过人声。\n\n【对白：讲述者】今晚，不必急着给生活一个答案。把未完成的事留给明天，先照顾好此刻的自己。\n\n【音乐】极轻的钢琴，在尾音后慢慢淡出。"
    @State private var voiceDescription = ""
    @State private var format = "WAV"
    @State private var sampleRate = "48 kHz"
    @State private var candidates = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            modes
            editorCard
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .background(StudioPalette.background)
        .navigationTitle("创作台")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Label("界面预览", systemImage: "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            TextField("作品名称", text: $name)
                .font(StudioTypography.serif(30))
                .textFieldStyle(.plain)
                .accessibilityLabel("作品名称，界面样例")
                .frame(maxWidth: 460)

            Label("界面样例", systemImage: "eye")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(StudioPalette.green)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(StudioPalette.greenSoft, in: Capsule())

            Spacer()

            Menu {
                Button("空白草稿") {}
                    .disabled(true)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .help("草稿功能将在后续版本接入")
        }
        .frame(height: 42)
    }

    private var modes: some View {
        HStack(spacing: 8) {
            ForEach(CreationMode.allCases) { item in
                Button {
                    mode = item
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .foregroundStyle(mode == item ? Color.white : Color.primary)
                        .background(mode == item ? StudioPalette.green : StudioPalette.surface,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .stroke(mode == item ? StudioPalette.green : StudioPalette.stroke))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == item ? [.isSelected] : [])
            }
        }
    }

    private var editorCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                scriptPane
                Rectangle()
                    .fill(StudioPalette.stroke)
                    .frame(width: 1)
                inspector
                    .frame(width: 294)
            }
            .frame(maxHeight: .infinity)

            Divider()
            footer
        }
        .background(StudioPalette.surface,
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioPalette.stroke))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .frame(maxHeight: .infinity)
    }

    private var scriptPane: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center) {
                Text("创作脚本")
                    .font(StudioTypography.serif(20))
                Spacer()
                HStack(spacing: 5) {
                    insertionButton("角色", symbol: "person")
                    insertionButton("对白", symbol: "text.bubble")
                    insertionButton("时间戳", symbol: "clock")
                    insertionButton("音效", symbol: "sparkles")
                    insertionButton("音乐", symbol: "music.note")
                }
            }

            TextEditor(text: $script)
                .font(StudioTypography.serif(17))
                .lineSpacing(8)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(StudioPalette.background,
                            in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioPalette.stroke))
                .accessibilityLabel("创作脚本，界面样例")

            HStack {
                Text("脚本仅供界面预览，尚未保存")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(script.unicodeScalars.count) / 3000 字")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private func insertionButton(_ title: String, symbol: String) -> some View {
        Button {} label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .disabled(true)
        .help("结构化插入将在后续版本接入")
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("声音与输出")
                .font(StudioTypography.serif(18))
            voiceInspector

            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private var voiceInspector: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("描述你想要的声音")
                .font(.system(size: 13, weight: .semibold))

            TextEditor(text: $voiceDescription)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 100)
                .background(StudioPalette.background,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioPalette.stroke))
                .accessibilityLabel("声音描述，界面样例")

            Button {} label: {
                Label("添加参考音色", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(true)

            Text("参考音频会在每次确认生成后上传")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("常用输出设置")
                .font(.system(size: 13, weight: .semibold))

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("输出格式")
                    Picker("格式", selection: $format) {
                        Text("MP3").tag("MP3")
                        Text("WAV").tag("WAV")
                        Text("PCM").tag("PCM")
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("采样率")
                    Picker("采样率", selection: $sampleRate) {
                        Text("48 kHz").tag("48 kHz")
                        Text("44.1 kHz").tag("44.1 kHz")
                        Text("24 kHz").tag("24 kHz")
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }
            .font(.system(size: 11))

            Button("高级设置…") {}
                .buttonStyle(.bordered)
                .disabled(true)

            Text("Seed 42 · 立体声 · 1.0×")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("尚未选择输出目录", systemImage: "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("更改…") {}
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(true)

            Spacer()

            Text("生成候选")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Picker("生成候选", selection: $candidates) {
                Text("1").tag(1)
                Text("2").tag(2)
                Text("3").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 105)

            Button {} label: {
                Label("生成音频", systemImage: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 134, height: 31)
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)
            .help("生成服务将在后续版本接入")
        }
        .padding(.horizontal, 20)
        .frame(height: 63)
    }
}
