# Qwen Audio Studio · Windows

独立的 Windows 10/11 x64 桌面客户端。使用与 macOS 版相同的 Next 服务契约和 42 个模板；原有 Swift/macOS 工程及数据库保持独立。

## 使用

1. 从本分支 GitHub Actions 的成功运行中下载 `Qwen-Audio-Studio-Windows-x64` 构建产物，解压其中的 ZIP
2. 将整个 `Qwen Audio Studio-win32-x64` 文件夹解压到本机，运行 `Qwen Audio Studio.exe`。不要只移动 EXE；旁边的 DLL、resources 和 locales 目录也必需
3. 在「设置」中输入百炼 API Key 和 Workspace ID，点击保存；AI 编剧另行配置 HTTPS Base URL、模型和对应 Key
4. 在创作台选择输出目录，填写脚本或应用模板。生成前核对完整 Prompt、参考音频和付费调用次数，再明确确认

不需要安装 Node.js、Python、ffmpeg、浏览器扩展或启动本地网页服务。当前便携包未做 Windows 代码签名；系统可能显示未知发布者提示。请核对来源与 SHA-256，并按组织的安全策略处理，不要关闭系统防护。

## 已实现

- AI 编剧：OpenAI-compatible HTTPS 接口、纯文本安全显示、最近 10 条消息上下文、`qwen-script` 一键导入
- 创作台：七种模式、自动保存与退出前保存、WAV/MP3/PCM、五种采样率、单/双声道、语速/音量/Seed/MP3 参数、1–3 候选
- 参考音色：WAV/MP3/M4A/OGG/Opus 导入，波形与明确起止点，最长 30 秒选区试听、单声道 PCM16 WAV 转换、稳定的 @voice1–3 绑定
- 灵感模板：与 macOS 相同的 42 个内置模板、变量填写、收藏、脚本保存为自建模板、覆盖确认
- 作品库：状态、搜索、收藏、试听、同一个播放器的 A/B 切换、导出、在资源管理器定位、原始草稿复用、可恢复回收站
- 故障恢复：收费请求不自动重试；未知结果明确显示可能已经计费；已获得结果的任务可只重试下载

## 数据与安全

- 应用数据通常位于 `%APPDATA%\Qwen Audio Studio`；业务记录是 `studio.json`，音色副本位于 `references`
- 生成文件放在选定输出目录中的 UUID 子文件夹，包含原始音频、Prompt 和验证报告；PCM 另带 `playback.wav` 用于试听
- Key 保存在 `credentials.bin`，使用 Windows DPAPI 绑定当前登录用户加密。不会回填到界面、日志或项目记录；切换 AI 编剧接口需为新接口重新保存 Key
- 请备份应用数据与音频输出目录。DPAPI 凭据不能作为跨电脑可移植备份，换电脑后需要重新输入
- 回收站是可恢复的逻辑移除；音频不会被永久删除。移除音色后保留私有副本，不再出现在音色列表或允许新上传；首版不提供自动磁盘清理
- 每批生成重新确认脚本和参考音频上传。真实生成和 AI 编剧可能产生服务商费用；自动化测试完全使用合成素材与假服务

## 开发与验证

需要 Node.js 24 和 npm；运行桌面测试与打包后的启动测试需要 Windows。

```powershell
cd windows
npm ci
npm run check
npm test
npx playwright install chromium
npm run test:ui
npm run test:desktop
npm run package:win
node scripts/smoke-package.cjs
```

`npm ci` 会从 Electron 官方发布源安装锁定版本。构建脚本可以在 Linux 交叉打包 Windows x64，但这不能替代 Windows 原生启动验证。

CI 位于 `.github/workflows/windows.yml`，依次运行静态检查、Node 测试、浏览器交互、真实 Electron/DPAPI/MP3 解码、Windows 打包和打包后启动。成功构建上传 ZIP、SHA-256 与测试截图，保留 14 天。

## 与 macOS 版的边界

- 这是 Electron 桌面版，不是 SwiftUI/WPF 原生控件移植；自带桌面运行时，包体较大
- Windows 数据库独立，暂不导入 macOS SQLite、旧网页版历史或 macOS 安全作用域书签
- 首版仅 x64 便携 ZIP，暂无 ARM64、安装器、自动更新或签名发行
- 自建模板保存脚本文本，不包含音色或输出参数；尚无自建变量编辑器、模板撤销、独立项目历史版本管理或作品最终版标记
- A/B 使用同一播放器切换；不是多轨编辑器，暂无循环选区和波形剪辑成品功能
- 外观为固定浅色主题；尚未完成 Windows Narrator、不同 DPI 和物理音频设备的人工验收

## 最后需要在 Windows 电脑确认

详见 [验收记录与集中检查清单](../docs/windows/QA.md)。不要把假服务测试当成真实账户生成或听感验收。
