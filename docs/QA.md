# 原生版最终 QA 记录

时间：2026-09-25。范围：当前 Apple Silicon Mac、macOS 14+ 目标；只使用合成或公开数据。所有“通过”均限于其证据所覆盖的路径。`docs/qa/task10/` 的 PNG 由签名原生 `.app` 的 `NSWindow`/`NSHostingView` 自截产生，2× 像素；截图根目录与合成 SQLite 均隔离，未使用真实密钥、私人音频或旧版数据库。

| 需求组 | 已有证据 | 状态与边界 |
| --- | --- | --- |
| 1. 完全原生运行与单屏布局 | `scripts/build-app.sh`；`docs/qa/task10/creation-window-checks.txt`；`otool -L` 仅系统库 | 1120×720、1280×720、1400×860、1600×900 均有浅/深 2× 截图，创作台窗口无整体滚动；长脚本只在编辑区滚动。 |
| 2. 明暗模式、字体、对齐与精简导航 | `docs/qa/task10/creation-*-*.png`、`library-*-*.png`、`templates-*-*.png`；思源宋体与 OFL 随 App 打包 | 截图人工核查，无主要控件溢出；设备级辅助显示设置未覆盖。 |
| 3. 七种模式与可编辑创作台 | `StudioModelsTests`、`PromptCompilerTests`、`AppStateTests`；创作台截图 | 模式和脚本编辑自动验证；实体键盘全面走查待验。 |
| 4. 草稿自动保存、重启恢复、版本与冲突 | `DraftTests`、`AppStateTests`、`EditorTests`、`TemplateApplicationTests` | SQLite 持久、选择旧项目恢复、Cmd-S/Undo/版本冲突有自动测试。 |
| 5. 作品库、筛选与可恢复删除 | `LibraryTests`、`LibraryScreenTests`、`AssetRecoveryTests`；`library-*-*.png` | 合成记录测试覆盖搜索、筛选、翻页、元数据、归档、回收与缺失文件；实际 Finder 点击待人工复核。 |
| 6. 结果试听及同位置 A/B | `AudioPlaybackControllerTests`、`ResultScreenTests`、`docs/qa/result-playback/`、`docs/qa/reference-audio/reference-audio-checks.txt` | 合成音频覆盖同位置切换、循环和单一播放所有权；实体扬声器听感及外接设备切换待验。 |
| 7. 七类×六个模板 | `TemplateEngineTests`、`TemplateVariableFormTests`；打包内 `--verify-templates` 返回 42/42；模板截图 | 变量、预览、收藏、自建、撤销及重启持久已自动验证。 |
| 8. 参考音色导入/裁剪/复用 | `ReferenceAudioTests`、`VoiceSheetTests`、`docs/qa/reference-audio/` | WAV、MP3、M4A、OGG Opus 合成素材解码；40 秒 OGG 尾段裁剪、质量提示、临时/持久库、原生滑块键盘箭头已验。真人声线效果未验。 |
| 9. 输出文件夹与 Finder | `OutputDirectoryTests`、`OutputFolderPickerTests`、`AssetRecoveryTests` | 书签跨进程重开、任务目录唯一性、撤销授权与文件恢复已验；原生输出选择框此前单独通过，最终 Finder 点击待验。 |
| 10. 设置、Keychain、帮助与环境检查 | `SettingsTests`、`NextClientTests`；`settings-*-*.png` | 密钥与 Workspace ID 分开保存且不回填；截图演示模式不读取 Keychain；官方帮助链接和本地检查代码已核，真实账户权限待短句冒烟。 |
| 11. 生成预检、收费确认、候选与任务生命周期 | `GenerationServiceTests`、`NextClientTests`、`GenerationSheetTests`、`StudioStoreTests` | 假 provider 路径测试：一次确认、幂等、排队取消、未知结果不重发、仅下载 GET 重试。真实付费 Next 调用由单独明确的短句冒烟验收。 |
| 12. SQLite 元数据与旧版只读迁移 | `LegacyImportTests`、`ImportSheetTests`；`docs/qa/task10/import-*-sheet.png` | V1 JSON/V2 SQLite、WAL、缺文件、恶意路径、失败回滚、ID 与音频关系由合成 fixture 验证；真实旧库未导入。原生目录面板自动取消探针在此桌面会话两次 70 秒超时，须人手点击复核。 |
| 13. 打包、端到端与文档 | `scripts/test-build-dmg.sh`、`scripts/verify-dmg-install.sh`、本文件与 README | DMG 已 `hdiutil verify`/挂载，Applications 链接、strict ad-hoc 验签、资源与 42 模板通过；临时 Applications 两次隔离原生 UI 启动并重新打开同一 SQLite，项目计数 7→14。Developer ID 证书为 0，未公证。 |

## 本轮执行和待验

- 串行完整 Swift Testing 在正常本机权限下新鲜执行：188 项通过，1 项系统原生面板测试按设计跳过。新增的导入取消保持预览测试另有单独红/绿验证；该单元测试使用可控选择结果，不能替代真实 `NSOpenPanel` 点击。
- `scripts/test-build-dmg.sh`：先因缺少打包脚本失败，再在补齐脚本后于本机正常权限通过。沙盒权限下 `hdiutil create` 返回 `Device not configured`，系统磁盘映像服务需要本机权限。
- `scripts/verify-dmg-install.sh`：映像校验通过，挂载与复制到明确临时 Applications 路径，严格验签后第一次/第二次隔离原生窗口启动均退出 0；第二次重开同一合成 SQLite，项目计数 7→14。首次构造验收脚本时，固定合成请求 ID 导致重启种子数据冲突；改为每次唯一 ID 后复测通过。未改系统 `/Applications`。
- `scripts/test-capture-sizes.sh`：先因缺少 1400/1600 截图失败，增加四尺寸自截后通过。主要页面及导入 sheet 的浅/深 PNG 在 `docs/qa/task10/`；设置是独立 780×590 内容窗口，因此其不同轮次截图实际尺寸以对应 `settings-window-checks.txt` 为准。
- 导入选择框的 `NativeImportDialogQA` 真实 `NSOpenPanel.runModal` 探针两次触发 70 秒看门狗，未取得点击通过证据。实际键盘验证包括原生音色裁剪滑块的右方向键、编辑器原生 Undo 与 Cmd-S 草稿保存自动测试；全界面 Tab 顺序、实体 VoiceOver 朗读、所有 Finder/菜单点击、真人听感、真实百炼 POST 尚未完成，这些项目不得标记为通过。
- 代码签名 `codesign -dv` 显示 `Signature=adhoc`、`TeamIdentifier=not set`；`security find-identity -v -p codesigning` 为 0。`spctl` 在当前环境报 `internal error in Code Signing subsystem`，不能据此宣称 Gatekeeper 公共分发通过。
