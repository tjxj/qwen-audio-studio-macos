# Next 服务契约与安全边界

本应用仅连接 `qwen-audio-3.1-tts-next`，地域固定为北京。下列约束用于原生客户端、预检与假服务测试；接口更新时，先核对[阿里云 Next 文档](https://help.aliyun.com/zh/model-studio/qwen-audio-3-1-tts-next)及[音频生成 API 文档](https://help.aliyun.com/zh/model-studio/audio-generation-api)。

## 请求

- URL：`https://<Workspace ID>.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer`。Workspace ID 只能包含 ASCII 字母、数字和连字符，拼接 URL 前验证。
- 方法 `POST`；请求头 `Authorization: Bearer <API Key>`、`Content-Type: application/json`。两个凭据只从本机 Keychain 读取，绝不写进项目数据、报告、日志或截图。
- JSON 顶层 `model` 固定为 `qwen-audio-3.1-tts-next`，`input` 包含 `text_prompt`、`references`、`format`、`sample_rate`、`channels`、`volume`、`rate`、`seed`、`enable_cbr`、`bit_rate`、`quality`、`enable_aigc_tag`。原生客户端不得附加其它模型选择。
- 旧网页版在用户钥匙串中的服务名为 `QwenAudioStudio.DashScopeAPIKey` 与 `QwenAudioStudio.WorkspaceID`，账户名为当前 macOS 账户。设置页可提供显式“读取已有本地配置”，读取后存入原生应用自己的钥匙串项目；不修改或删除旧项目。读取失败时保留手动填写途径。
- `text_prompt` 以最终编译后的 Unicode 标量计，最多 3000。参考音频最多三条；每条转换并验证为服务支持的音频格式，最长 30 秒、最大 10 MiB。上传前展示文件名、数量和本批次授权；授权不沿用到下一批。
- 输出格式限定 `wav`、`mp3`、`pcm`；采样率为 8000、16000、24000、44100、48000 Hz；声道为 1 或 2；音量 0–100，语速 0.5–2.0，MP3 VBR 质量 0–9。MP3 CBR 码率需随采样率预检：8 kHz 为 8–64 kbps，16/24 kHz 为 8–160 kbps，44.1/48 kHz 为 32–320 kbps；区间内也须符合实际 MP3 编码档位。[官方 API 文档](https://help.aliyun.com/zh/model-studio/audio-generation-api)为最终依据。

## 响应与幂等

HTTP 200 仍须校验 JSON 对象及 `output.audio.url`。保存 `request_id`、状态和必要的脱敏元数据；下载链接有效期通常为 24 小时，并带有 `expires_at`，音频应及时下载到用户授权的输出目录。下载完成后校验实际容器、可解码性、时长与大小，再对外标记为完成。

客户端生成一次不可复用的 `client_request_id`，将已确认的完整请求快照和哈希原子持久化，然后发送付费 POST。提交结果不确定时标记“结果待核查”，禁止自动重发；用户显式新建批次前先说明可能重复计费。多个候选使用不同种子，且每个候选独立记录请求阶段。仅下载 GET 可按有界策略重试。

所有自动化测试使用假服务、临时目录和合成音频。真实 Next 调用须作为单独标识的短文本冒烟测试执行一次，并记录成功与否及脱敏请求 ID。
