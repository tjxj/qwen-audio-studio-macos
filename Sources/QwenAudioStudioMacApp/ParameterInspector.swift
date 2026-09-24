import SwiftUI
import StudioCore

struct ParameterInspector: View {
    @Binding var params: GenerationParams
    var onAddVoice: () -> Void = {}
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("声音与输出").font(StudioTypography.serif(18))
            Text("在脚本的「角色」标签中描述声音、情绪和语气。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onAddVoice) {
                Label("添加参考音色", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .help("导入、裁剪或复用本机参考音色")
            Divider()
            Text("常用输出设置").font(.system(size: 13, weight: .semibold))
            Picker("格式", selection: $params.format) {
                Text("WAV").tag("wav")
                Text("MP3").tag("mp3")
                Text("PCM").tag("pcm")
            }
            Picker("采样率", selection: $params.sampleRate) {
                Text("8 kHz").tag(8000)
                Text("16 kHz").tag(16000)
                Text("24 kHz").tag(24000)
                Text("44.1 kHz").tag(44100)
                Text("48 kHz").tag(48000)
            }
            HStack {
                Text("语速")
                Slider(value: Binding(get: { params.rate }, set: { params.rate = ($0 * 10).rounded() / 10 }), in: 0.5...2)
                Text(params.rate.formatted(.number.precision(.fractionLength(1))) + "×")
                    .monospacedDigit().frame(width: 34)
            }
            HStack {
                Text("音量")
                Slider(value: Binding(get: { Double(params.volume) }, set: { params.volume = Int($0.rounded()) }), in: 0...100)
                Text("\(params.volume)").monospacedDigit().frame(width: 34)
            }
            Button("高级设置…") { showAdvanced = true }
                .sheet(isPresented: $showAdvanced) { advanced }
            Text("更改随草稿自动保存，生成前会再次校验。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(18)
        .task {
            if ProcessInfo.processInfo.arguments.contains("--capture-sheet=advanced") { showAdvanced = true }
        }
    }

    private var advanced: some View {
        Form {
            Text("高级输出设置").font(StudioTypography.serif(18))
            Picker("声道", selection: $params.channels) {
                Text("单声道").tag(1)
                Text("立体声").tag(2)
            }
            TextField("Seed", value: $params.seed, format: .number.grouping(.never))
            Toggle("固定比特率（MP3）", isOn: $params.enableCBR)
                .disabled(params.format != "mp3")
            Picker("比特率", selection: $params.bitRate) {
                ForEach([64, 128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
            }
            .disabled(params.format != "mp3" || !params.enableCBR)
            Stepper("音质：\(params.quality)", value: $params.quality, in: 0...9)
                .disabled(params.format != "mp3" || params.enableCBR)
            Toggle("添加 AI 生成标识", isOn: $params.enableAIGCTag)
            Button("完成") { showAdvanced = false }.keyboardShortcut(.defaultAction)
        }
        .formStyle(.grouped)
        .frame(width: 330, height: 350)
    }
}
