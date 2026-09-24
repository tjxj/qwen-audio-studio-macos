# Task 1 原生窗口验收

日期：2026-09-24。范围：可编译的 SwiftUI/AppKit 主窗口、七种稳定模式、三个导航页面、macOS 设置场景和本地字体资源。

## 已实现

- 创作台在 1280 × 720 内容区内展示七模式、脚本、声音描述、常用输出参数、输出目录状态、候选数与生成入口。脚本在编辑器内部滚动。
- 作品库与灵感模板有原生页面；设置使用 macOS `Settings` 场景。未接入的操作被禁用，样例内容明确标为“界面样例”。
- 字体为思源宋体 VF 的 7,543 字形子集，静态 TTF 内部家族名改为 `Qwen Studio Serif`。资源内含 OFL 1.1 全文，应用启动时通过 CoreText 注册。
- `.app` 使用 Swift Package release 构建，并在独立临时目录签名后复制到 `dist/`。

## 验证

- RED：先写 `StudioModelsTests`，首次有效 `swift test` 失败于缺少 `CreationMode` 与 `StudioLayout`。
- GREEN：`swift test --disable-sandbox` 运行 3 个测试，全部通过。此机 Command Line Tools 的 Testing.framework 需要通过 `-F /Library/Developer/CommandLineTools/Library/Developer/Frameworks` 指定。
- `zsh scripts/build-app.sh` 完成 release 编译、`.app` 打包与 ad hoc 签名。`codesign --verify --verbose=2` 和 `plutil -lint` 均通过。
- 从 release `.app` 原生进程以 `--capture-ui=<目录>` 触发 AppKit 窗口内容 bitmap 捕获。每张为 2560 × 1440 PNG，对应 1280 × 720 Retina 2× 内容区；浅色与深色均已人工查看，底部生成栏和右侧参数完整可见。

截图：[浅色](../screenshots/task1/creation-light-1280.png)、[深色](../screenshots/task1/creation-dark-1280.png)。

## 当前限制

Task 1 为窗口与数据模型基础。项目保存、42 模板、音频生成、播放、迁移与 DMG 由后续任务实现。此机 CUA 原生管道在读取窗口时关闭，因而本轮采用应用自身的原生窗口内容捕获；尚未做 CUA 点击与 VoiceOver 检查。当前签名为本机开发用途的 ad hoc 签名。
