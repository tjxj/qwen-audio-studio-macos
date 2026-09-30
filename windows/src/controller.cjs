"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { randomUUID, createHash } = require("node:crypto");
const { sanitizeState } = require("./security.cjs");
const { chatEndpoint, requestChat } = require("./core/chat.cjs");
const MAX_SOURCE = 50 * 1024 * 1024;
const MAX_AUDIO = 200 * 1024 * 1024;
function object(value) {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error("数据格式无效。");
}
function text(value, max, label) {
  if (typeof value !== "string" || value.length > max || value.includes("\0"))
    throw new Error(`${label}无效或过长。`);
  return value;
}
function cleanDraft(value) {
  object(value);
  if (
    ![
      "podcast",
      "advertisement",
      "audiobook",
      "drama",
      "game",
      "narration",
      "auto",
    ].includes(value.mode)
  )
    throw new Error("创作模式无效。");
  object(value.params);
  if (!Array.isArray(value.bindings) || value.bindings.length > 3)
    throw new Error("最多支持三段参考音色。");
  return {
    name: text(value.name, 160, "项目名称"),
    mode: value.mode,
    prompt: text(value.prompt, 20000, "脚本"),
    params: JSON.parse(JSON.stringify(value.params)),
    bindings: value.bindings.map((b) => {
      object(b);
      if (!Number.isInteger(b.slot) || b.slot < 1 || b.slot > 3)
        throw new Error("音色槽位无效。");
      return {
        referenceID: text(b.referenceID, 100, "音色标识"),
        alias: text(b.alias || "", 160, "音色别名"),
        slot: b.slot,
      };
    }),
  };
}
function inside(file, root) {
  const relative = path.relative(fs.realpathSync(root), fs.realpathSync(file));
  return (
    relative !== "" &&
    !relative.startsWith(".." + path.sep) &&
    relative !== ".." &&
    !path.isAbsolute(relative)
  );
}
class StudioController {
  constructor({
    store,
    vault,
    service,
    directory,
    dialog,
    shell,
    templates,
    notify = () => {},
    window,
    chatClient = requestChat,
  }) {
    Object.assign(this, {
      store,
      vault,
      service,
      directory,
      dialog,
      shell,
      templates,
      notify,
      window,
      chatClient,
    });
    this.chatBusy = false;
  }
  bootstrap() {
    const data = sanitizeState(this.store.snapshot());
    let secrets = {},
      credentialError;
    try {
      secrets = this.vault.load();
      data.credentials = this.vault.status();
      data.credentials.hasChatKey = Boolean(
        secrets.chatAPIKey &&
          secrets.chatEndpoint === chatEndpoint(data.settings.chatBaseURL),
      );
    } catch (e) {
      credentialError = e.message;
      data.credentials = {
        hasAPIKey: false,
        hasChatKey: false,
        encryptionAvailable: this.vault.available?.() || false,
      };
    }
    data.settings.workspaceID = secrets.workspaceID || "";
    data.templates = [...this.templates, ...data.customTemplates];
    data.references = data.references.filter(
      (r) =>
        !this.store.snapshot().references.find((x) => x.id === r.id)?.trashed,
    );
    data.credentialError = credentialError;
    return data;
  }
  changed() {
    this.notify(this.bootstrap());
  }
  async saveDraft(value) {
    const draft = cleanDraft(value);
    this.store.update((s) => {
      s.draft = draft;
    });
    this.changed();
    return this.bootstrap();
  }
  async saveSettings(value) {
    object(value);
    const previous = this.store.snapshot();
    const settings = { ...previous.settings };
    let keys;
    try {
      keys = this.vault.load();
    } catch {
      keys = {};
    }
    if (value.chatBaseURL !== undefined) {
      text(value.chatBaseURL, 2048, "AI 编剧地址");
      chatEndpoint(value.chatBaseURL);
      if (
        chatEndpoint(value.chatBaseURL) !==
        chatEndpoint(settings.chatBaseURL || "https://api.deepseek.com/v1")
      ) {
        keys.chatAPIKey = "";
        keys.chatEndpoint = "";
      }
      settings.chatBaseURL = value.chatBaseURL.trim().replace(/\/+$/, "");
    }
    if (value.chatModel !== undefined) {
      settings.chatModel = text(value.chatModel, 200, "模型名称").trim();
      if (!settings.chatModel) throw new Error("模型名称不能为空。");
    }
    for (const key of ["apiKey", "chatAPIKey", "workspaceID"]) {
      if (value[key] !== undefined) {
        const input = text(value[key], 4096, "凭据").trim();
        if (/[\r\n]/.test(input)) throw new Error("凭据不能包含换行。");
        if (key === "workspaceID" || input) keys[key] = input;
        if (key === "chatAPIKey" && input)
          keys.chatEndpoint = chatEndpoint(settings.chatBaseURL);
      }
    }
    if (
      keys.workspaceID &&
      !/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(keys.workspaceID)
    )
      throw new Error("Workspace ID 无效。");
    const keyChanged =
      ["apiKey", "chatAPIKey", "workspaceID"].some(
        (k) => value[k] !== undefined,
      ) ||
      (value.chatBaseURL !== undefined && keys.chatAPIKey === "");
    if (keyChanged) this.vault.save(keys);
    this.store.update((s) => {
      s.settings = settings;
    });
    this.changed();
    return this.bootstrap();
  }
  async chooseOutputDirectory() {
    const result = await this.dialog.showOpenDialog(this.window, {
      title: "选择音频输出目录",
      properties: ["openDirectory", "createDirectory"],
    });
    if (result.canceled || !result.filePaths?.[0]) return null;
    const selected = fs.realpathSync(result.filePaths[0]);
    if (!fs.statSync(selected).isDirectory())
      throw new Error("请选择有效目录。");
    fs.accessSync(selected, fs.constants.W_OK);
    this.store.update((s) => {
      s.settings.outputDirectory = selected;
    });
    this.changed();
    return selected;
  }
  async preflight({ draft, candidates }) {
    return this.service.preflight(cleanDraft(draft), candidates);
  }
  async cancelPreflight(token) {
    this.service.cancelPreflight(token);
    return { cancelled: true };
  }
  async submit(token) {
    text(token, 100, "确认标识");
    await this.service.submit(token);
    return { accepted: true };
  }
  async retryDownload(id) {
    text(id, 100, "任务标识");
    await this.service.retryDownload(id);
    return { accepted: true };
  }
  async pickReference() {
    const result = await this.dialog.showOpenDialog(this.window, {
      title: "选择参考音色（最多 50 MiB、10 分钟）",
      properties: ["openFile"],
      filters: [
        { name: "音频文件", extensions: ["wav", "mp3", "m4a", "ogg", "opus"] },
      ],
    });
    if (result.canceled || !result.filePaths?.[0]) return null;
    const file = result.filePaths[0];
    if (!/\.(wav|mp3|m4a|ogg|opus)$/i.test(file))
      throw new Error("不支持该音频格式。");
    const size = fs.statSync(file).size;
    if (size === 0 || size > MAX_SOURCE)
      throw new Error("参考源文件须为 1 字节到 50 MiB。");
    const data = fs.readFileSync(file);
    if (data.length > MAX_SOURCE) throw new Error("文件过大。");
    return { name: path.basename(file), data: new Uint8Array(data) };
  }
  async saveReference(value) {
    object(value);
    const name = text(value.name, 160, "音色名称").trim();
    if (!name) throw new Error("音色名称不能为空。");
    if (!ArrayBuffer.isView(value.data) && !Array.isArray(value.data))
      throw new Error("音频数据无效。");
    const bytes = Buffer.from(value.data);
    if (!bytes.length || bytes.length > 10 * 1024 * 1024)
      throw new Error("参考片段须不大于 10 MiB。");
    const { inspectWav } = require("./core/audio.cjs");
    const info = inspectWav(bytes);
    if (
      info.channels !== 1 ||
      info.bitsPerSample !== 16 ||
      info.duration <= 0 ||
      info.duration > 30
    )
      throw new Error("参考音色须为不超过 30 秒的单声道 PCM16 WAV。");
    const id = randomUUID();
    const folder = path.join(this.directory, "references");
    fs.mkdirSync(folder, { recursive: true });
    const target = path.join(folder, `${id}.wav`);
    fs.writeFileSync(target, bytes, { flag: "wx", mode: 0o600 });
    const reference = {
      id,
      name,
      path: target,
      mimeType: "audio/wav",
      duration: info.duration,
      sampleRate: info.sampleRate,
      channels: 1,
      contentHash: createHash("sha256").update(bytes).digest("hex"),
    };
    try {
      this.store.update((s) => s.references.push(reference));
    } catch (e) {
      fs.unlinkSync(target);
      throw e;
    }
    this.changed();
    return {
      id,
      name,
      duration: info.duration,
      sampleRate: info.sampleRate,
      channels: 1,
    };
  }
  async removeReference(id) {
    const ref = this.store
      .snapshot()
      .references.find((r) => r.id === id && !r.trashed);
    if (!ref) throw new Error("找不到音色。");
    if (this.service.isBusy)
      throw new Error("请等待当前生成完成后再移除音色。");
    this.store.update((s) => {
      s.references.find((r) => r.id === id).trashed = true;
    });
    this.changed();
    return this.bootstrap();
  }
  task(id) {
    text(id, 100, "任务标识");
    const task = this.store.snapshot().tasks.find((t) => t.id === id);
    if (!task) throw new Error("找不到任务。");
    return task;
  }
  asset(task, playback = false) {
    const file = playback
      ? task.playbackPath || task.outputPath
      : task.outputPath;
    if (
      !file ||
      !task.directory ||
      !task.outputDirectory ||
      !inside(task.directory, task.outputDirectory) ||
      !inside(file, task.directory) ||
      !fs.statSync(file).isFile()
    )
      throw new Error("音频文件缺失或位置已改变。");
    const size = fs.statSync(file).size;
    if (size < 1 || size > MAX_AUDIO) throw new Error("音频文件大小无效。");
    return file;
  }
  async readAudio(value) {
    object(value);
    let file, mimeType;
    if (value.kind === "reference") {
      const ref = this.store
        .snapshot()
        .references.find((r) => r.id === value.id && !r.trashed);
      if (!ref || !inside(ref.path, path.join(this.directory, "references")))
        throw new Error("找不到音色。");
      file = ref.path;
      mimeType = "audio/wav";
    } else if (value.kind === "task") {
      const task = this.task(value.id);
      if (task.status !== "success") throw new Error("音频尚未完成。");
      file = this.asset(task, true);
      mimeType =
        path.extname(file).toLowerCase() === ".mp3"
          ? "audio/mpeg"
          : "audio/wav";
    } else throw new Error("不支持的音频来源。");
    if (fs.statSync(file).size > MAX_AUDIO) throw new Error("音频文件过大。");
    return { data: new Uint8Array(fs.readFileSync(file)), mimeType };
  }
  async updateTask(value) {
    object(value);
    if (
      Object.keys(value).some(
        (k) => !["id", "name", "favorite", "trashed"].includes(k),
      )
    )
      throw new Error("不可修改任务内部字段。");
    const task = this.task(value.id);
    if (
      ![
        "success",
        "failed",
        "uncertain",
        "interrupted",
        "download_failed",
      ].includes(task.status)
    )
      throw new Error("运行中的任务不能修改。");
    if (value.name !== undefined && !text(value.name, 160, "作品名称").trim())
      throw new Error("作品名称不能为空。");
    for (const key of ["favorite", "trashed"])
      if (value[key] !== undefined && typeof value[key] !== "boolean")
        throw new Error("任务选项无效。");
    this.store.update((s) => {
      const target = s.tasks.find((t) => t.id === value.id);
      for (const key of ["name", "favorite", "trashed"])
        if (value[key] !== undefined) target[key] = value[key];
    });
    this.changed();
    return this.bootstrap();
  }
  async revealTask(id) {
    const file = this.asset(this.task(id));
    this.shell.showItemInFolder(file);
    return { opened: true };
  }
  async exportTask(id) {
    const task = this.task(id),
      source = this.asset(task);
    const result = await this.dialog.showSaveDialog(this.window, {
      title: "导出音频",
      defaultPath: `Qwen-${task.id}${path.extname(source)}`,
      filters: [{ name: "音频", extensions: [path.extname(source).slice(1)] }],
    });
    if (result.canceled || !result.filePath) return null;
    if (path.resolve(result.filePath) === path.resolve(source)) return source;
    fs.copyFileSync(source, result.filePath);
    return result.filePath;
  }
  async expandTemplate({ id, values }) {
    const item = [
      ...this.templates,
      ...this.store.snapshot().customTemplates,
    ].find((t) => t.id === id);
    if (!item) throw new Error("找不到模板。");
    return require("./core/domain.cjs").expandTemplate(item, values);
  }
  async saveTemplate(value) {
    object(value);
    const all = this.store.snapshot().customTemplates;
    const id = value.id || `user-${randomUUID()}`;
    if (this.templates.some((t) => t.id === id) || value.source === "builtin")
      throw new Error("内置模板只读。");
    const item = {
      id: text(id, 100, "模板标识"),
      source: "user",
      version: 1,
      name: text(value.name, 80, "模板名称"),
      mode: value.mode,
      description: text(value.description || "", 300, "模板说明"),
      tags: [],
      role_count: 1,
      prompt_pattern: text(value.prompt_pattern, 3000, "模板正文"),
      variables: [],
    };
    require("./core/domain.cjs").expandTemplate(item, {});
    this.store.update((s) => {
      const index = s.customTemplates.findIndex((t) => t.id === id);
      if (index < 0) s.customTemplates.push(item);
      else s.customTemplates[index] = item;
    });
    this.changed();
    return this.bootstrap();
  }
  async removeTemplate(id) {
    if (!this.store.snapshot().customTemplates.some((t) => t.id === id))
      throw new Error("只能移除自建模板。");
    this.store.update((s) => {
      s.customTemplates = s.customTemplates.filter((t) => t.id !== id);
      s.templateFavorites = s.templateFavorites.filter((x) => x !== id);
    });
    this.changed();
    return this.bootstrap();
  }
  async favoriteTemplate({ id, favorite }) {
    if (
      typeof favorite !== "boolean" ||
      ![...this.templates, ...this.store.snapshot().customTemplates].some(
        (t) => t.id === id,
      )
    )
      throw new Error("模板收藏无效。");
    this.store.update((s) => {
      s.templateFavorites = s.templateFavorites.filter((x) => x !== id);
      if (favorite) s.templateFavorites.push(id);
    });
    this.changed();
    return this.bootstrap();
  }
  async chat({ text: message }) {
    if (this.chatBusy) throw new Error("请等待当前编剧回复。");
    message = text(message, 10000, "消息").trim();
    if (!message) throw new Error("请填写消息。");
    const credentials = this.vault.load(),
      settings = this.store.snapshot().settings;
    if (
      !credentials.chatAPIKey ||
      credentials.chatEndpoint !== chatEndpoint(settings.chatBaseURL)
    )
      throw new Error("请在设置中为当前 AI 编剧接口重新保存 API Key。");
    this.chatBusy = true;
    try {
      this.store.update((s) => {
        s.chatMessages.push({
          id: randomUUID(),
          role: "user",
          content: message,
        });
        s.chatMessages = s.chatMessages.slice(-100);
      });
      this.changed();
      const content = await this.chatClient({
        baseURL: settings.chatBaseURL,
        apiKey: credentials.chatAPIKey,
        model: settings.chatModel,
        messages: this.store.snapshot().chatMessages,
      });
      this.store.update((s) => {
        s.chatMessages.push({ id: randomUUID(), role: "assistant", content });
        s.chatMessages = s.chatMessages.slice(-100);
      });
      this.changed();
      return { messages: this.store.snapshot().chatMessages };
    } finally {
      this.chatBusy = false;
    }
  }
  async clearChat() {
    if (this.chatBusy) throw new Error("回复生成中，暂时不能清空。");
    this.store.update((s) => {
      s.chatMessages = [];
    });
    this.changed();
    return this.bootstrap();
  }
}
module.exports = { StudioController, cleanDraft, inside };
