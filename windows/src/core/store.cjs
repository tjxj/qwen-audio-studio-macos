"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { randomUUID } = require("node:crypto");
const { DEFAULT_PARAMS } = require("./domain.cjs");
const clone = (value) => structuredClone(value);
const ACTIVE_STATES = new Set([
  "queued",
  "preparing",
  "requesting",
  "downloading",
  "validating",
]);

function defaults() {
  return {
    version: 1,
    draft: {
      name: "未命名作品",
      mode: "podcast",
      prompt: "",
      params: clone(DEFAULT_PARAMS),
      bindings: [],
    },
    settings: {
      outputDirectory: "",
      chatBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
      chatModel: "qwen-plus",
    },
    tasks: [],
    references: [],
    templateFavorites: [],
    customTemplates: [],
    chatMessages: [],
  };
}
function validate(data) {
  if (!data || data.version !== 1)
    throw new Error(
      "不支持的数据版本 (schema version)，请保留原文件并恢复备份。",
    );
  for (const key of [
    "tasks",
    "references",
    "templateFavorites",
    "customTemplates",
    "chatMessages",
  ]) {
    if (!Array.isArray(data[key]))
      throw new Error("本地数据库结构损坏，未覆盖原文件。");
  }
  if (
    !data.draft ||
    typeof data.draft !== "object" ||
    !data.settings ||
    typeof data.settings !== "object" ||
    !Array.isArray(data.draft.bindings)
  ) {
    throw new Error("本地数据库结构损坏，未覆盖原文件。");
  }
}

class Store {
  constructor(directory) {
    if (typeof directory !== "string" || !directory)
      throw new Error("需要有效的数据目录。");
    this.directory = path.resolve(directory);
    this.filePath = path.join(this.directory, "studio.json");
    this.data = null;
  }
  load() {
    if (this.data) return this.snapshot();
    fs.mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    let next;
    if (fs.existsSync(this.filePath)) {
      if (fs.statSync(this.filePath).size > 32 * 1024 * 1024)
        throw new Error("本地数据库超过安全读取上限，未覆盖原文件。");
      next = JSON.parse(fs.readFileSync(this.filePath, "utf8"));
      validate(next);
      let recovered = false;
      for (const task of next.tasks) {
        if (ACTIVE_STATES.has(task.status)) {
          task.previousStatus = task.status;
          task.status =
            task.previousStatus === "requesting" && !task.receipt
              ? "uncertain"
              : "interrupted";
          task.updatedAt = new Date().toISOString();
          task.error =
            task.status === "uncertain"
              ? "上次收费请求在结果确认前中断，可能已产生费用；不会自动重发，请先核查服务记录。"
              : "上次运行已中断，未自动重新生成；若已收到音频链接，可单独重试下载。";
          recovered = true;
        }
      }
      if (recovered) this._persist(next);
    } else {
      next = defaults();
      this._persist(next);
    }
    this.data = next;
    return this.snapshot();
  }
  snapshot() {
    if (!this.data) return this.load();
    return clone(this.data);
  }
  update(mutator) {
    if (!this.data) this.load();
    const next = clone(this.data);
    const result = mutator(next);
    if (result && typeof result.then === "function")
      throw new Error("本地保存必须使用同步事务。");
    validate(next);
    this._persist(next);
    this.data = next;
    return this.snapshot();
  }
  _persist(data) {
    const temporary = path.join(this.directory, `.studio-${randomUUID()}.tmp`);
    let fd;
    try {
      const encoded = JSON.stringify(data, null, 2);
      if (Buffer.byteLength(encoded) > 32 * 1024 * 1024)
        throw new Error("本地数据库超过安全写入上限。");
      fd = fs.openSync(temporary, "wx", 0o600);
      fs.writeFileSync(fd, encoded, "utf8");
      fs.fsyncSync(fd);
      fs.closeSync(fd);
      fd = undefined;
      fs.renameSync(temporary, this.filePath);
      // Windows does not support opening every directory for fsync. A directory
      // sync is best-effort only after the atomic rename has already committed.
      let directoryFD;
      try {
        directoryFD = fs.openSync(this.directory, "r");
        fs.fsyncSync(directoryFD);
      } catch {
        /* File fsync + atomic same-volume rename remain mandatory. */
      } finally {
        if (directoryFD !== undefined) {
          try {
            fs.closeSync(directoryFD);
          } catch {}
        }
      }
    } finally {
      if (fd !== undefined) fs.closeSync(fd);
      try {
        fs.unlinkSync(temporary);
      } catch (error) {
        if (error.code !== "ENOENT") {
          /* Do not mask the transaction failure. */
        }
      }
    }
  }
}
module.exports = { Store };
