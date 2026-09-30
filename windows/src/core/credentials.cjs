"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { randomUUID } = require("node:crypto");

class CredentialVault {
  constructor(directory, safeStorage, platform = process.platform) {
    this.directory = directory;
    this.file = path.join(directory, "credentials.bin");
    this.safeStorage = safeStorage;
    this.platform = platform;
  }
  available() {
    return (
      this.safeStorage.isEncryptionAvailable() &&
      !(
        this.platform === "linux" &&
        this.safeStorage.getSelectedStorageBackend?.() === "basic_text"
      )
    );
  }
  load() {
    if (!fs.existsSync(this.file)) return {};
    try {
      if (!this.available()) throw new Error();
      const result = JSON.parse(
        this.safeStorage.decryptString(fs.readFileSync(this.file)),
      );
      if (!result || typeof result !== "object" || Array.isArray(result))
        throw new Error();
      for (const [key, value] of Object.entries(result)) {
        if (
          !["apiKey", "workspaceID", "chatAPIKey", "chatEndpoint"].includes(
            key,
          ) ||
          typeof value !== "string"
        )
          throw new Error();
      }
      return result;
    } catch {
      throw new Error(
        "无法解密本机凭据。请使用原 Windows 账户，或在设置中重新保存凭据。",
      );
    }
  }
  save(value) {
    if (!this.available())
      throw new Error("操作系统安全加密不可用，拒绝明文保存凭据。");
    const clean = {};
    for (const key of ["apiKey", "workspaceID", "chatAPIKey", "chatEndpoint"]) {
      if (value[key] !== undefined) {
        if (
          typeof value[key] !== "string" ||
          value[key].length > 4096 ||
          /[\r\n\0]/.test(value[key])
        )
          throw new Error("凭据格式无效。");
        clean[key] = value[key].trim();
      }
    }
    if (
      clean.workspaceID &&
      !/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(clean.workspaceID)
    )
      throw new Error("Workspace ID 仅支持 1–63 位字母、数字和中间连字符。");
    fs.mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    const temp = `${this.file}.${randomUUID()}.tmp`;
    try {
      const fd = fs.openSync(temp, "wx", 0o600);
      try {
        fs.writeFileSync(
          fd,
          this.safeStorage.encryptString(JSON.stringify(clean)),
        );
        fs.fsyncSync(fd);
      } finally {
        fs.closeSync(fd);
      }
      fs.renameSync(temp, this.file);
    } finally {
      try {
        fs.unlinkSync(temp);
      } catch {}
    }
  }
  status() {
    const secrets = this.load();
    return {
      hasAPIKey: Boolean(secrets.apiKey),
      hasChatKey: Boolean(secrets.chatAPIKey),
      encryptionAvailable: this.available(),
    };
  }
}
module.exports = { CredentialVault };
