"use strict";
const {
  app,
  BrowserWindow,
  ipcMain,
  dialog,
  shell,
  safeStorage,
  Menu,
} = require("electron");
const path = require("node:path");
const fs = require("node:fs");
const { pathToFileURL } = require("node:url");
const { Store } = require("./core/store.cjs");
const { GenerationService } = require("./core/generation.cjs");
const { createCloseGuard } = require("./close-guard.cjs");
const { randomUUID } = require("node:crypto");
const { decodeAudio } = require("./decoder.cjs");
const { CredentialVault } = require("./core/credentials.cjs");
const { StudioController } = require("./controller.cjs");
const { validateSender } = require("./security.cjs");
const METHODS = new Set([
  "bootstrap",
  "saveDraft",
  "saveSettings",
  "chooseOutputDirectory",
  "preflight",
  "cancelPreflight",
  "submit",
  "retryDownload",
  "pickReference",
  "saveReference",
  "removeReference",
  "readAudio",
  "updateTask",
  "revealTask",
  "exportTask",
  "chat",
  "clearChat",
  "expandTemplate",
  "saveTemplate",
  "removeTemplate",
  "favoriteTemplate",
]);
async function startDesktop(options = {}) {
  app.setName("Qwen Audio Studio");
  app.setAppUserModelId("com.qwen.audiostudio.windows");
  if (options.directory) app.setPath("userData", options.directory);
  if (!app.requestSingleInstanceLock()) {
    app.quit();
    return null;
  }
  await app.whenReady();
  const directory = app.getPath("userData");
  const store = new Store(directory);
  store.load();
  const vault = options.vault || new CredentialVault(directory, safeStorage);
  let controller;
  const window = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 1120,
    minHeight: 720,
    show: false,
    title: "Qwen Audio Studio",
    backgroundColor: "#f4f5ee",
    icon: path.join(__dirname, "../resources/icon.png"),
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      allowRunningInsecureContent: false,
      spellcheck: false,
    },
  });
  Menu.setApplicationMenu(null);
  const document = path.join(__dirname, "renderer/index.html");
  const documentURL = pathToFileURL(document).href;
  const emit = () => {
    if (controller && !window.isDestroyed())
      window.webContents.send("studio:state", controller.bootstrap());
  };
  const service = new GenerationService({
    store,
    credentials: () => vault.load(),
    provider: options.provider,
    decodeAudio,
    outputDirectory: () => store.snapshot().settings.outputDirectory,
    onChange: emit,
  });
  controller = new StudioController({
    store,
    vault,
    service,
    directory,
    dialog: options.dialog || dialog,
    shell: options.shell || shell,
    templates: JSON.parse(
      fs.readFileSync(
        path.join(__dirname, "../resources/templates.json"),
        "utf8",
      ),
    ),
    notify: emit,
    window,
    chatClient: options.chatClient,
  });
  const session = window.webContents.session;
  session.setPermissionRequestHandler((_webContents, _permission, callback) =>
    callback(false),
  );
  session.setPermissionCheckHandler(() => false);
  session.webRequest.onBeforeRequest(
    { urls: ["http://*/*", "https://*/*", "ws://*/*", "wss://*/*"] },
    (_details, callback) => callback({ cancel: true }),
  );
  window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  window.webContents.on("will-navigate", (event) => event.preventDefault());
  window.webContents.on("will-attach-webview", (event) =>
    event.preventDefault(),
  );
  ipcMain.handle("studio:invoke", async (event, method, value) => {
    try {
      validateSender(event, window.webContents, documentURL);
      if (!METHODS.has(method)) throw new Error("不支持的操作。");
      return { ok: true, value: await controller[method](value) };
    } catch (error) {
      return {
        ok: false,
        error: error instanceof Error ? error.message : "操作未完成。",
      };
    }
  });
  app.on("second-instance", () => {
    if (window.isMinimized()) window.restore();
    window.show();
    window.focus();
  });
  let allowClose = false;
  function flushDraft() {
    return new Promise((resolve, reject) => {
      const id = randomUUID();
      const timer = setTimeout(
        () => finish(new Error("草稿保存未获确认，请稍后再试。")),
        10000,
      );
      function finish(error) {
        clearTimeout(timer);
        ipcMain.removeListener("studio:close-ready", listener);
        error ? reject(error) : resolve();
      }
      function listener(event, response) {
        try {
          validateSender(event, window.webContents, documentURL);
        } catch {
          return;
        }
        if (response?.id !== id) return;
        finish(
          response.ok
            ? null
            : new Error(
                "草稿保存失败。请检查可用磁盘空间后重试，窗口仍保持打开。",
              ),
        );
      }
      ipcMain.on("studio:close-ready", listener);
      window.webContents.send("studio:before-close", id);
    });
  }
  const requestClose = createCloseGuard({
    flush: flushDraft,
    isBusy: () => service.isBusy || controller.chatBusy,
    confirm: async () => {
      const result = await dialog.showMessageBox(window, {
        type: "warning",
        buttons: ["留在应用", "退出"],
        defaultId: 0,
        cancelId: 0,
        title: "任务仍在运行",
        message:
          "关闭应用不能撤销已经提交的收费请求。退出后将保留状态，不会自动重新提交。",
      });
      return result.response === 1;
    },
    close: () => {
      allowClose = true;
      window.close();
    },
    report: (error) => dialog.showErrorBox("未关闭应用", error.message),
  });
  window.on("close", (event) => {
    if (!allowClose) {
      event.preventDefault();
      void requestClose();
    }
  });
  window.on("closed", () => {
    ipcMain.removeHandler("studio:invoke");
    app.quit();
  });
  await window.loadFile(document);
  window.show();
  return { window, controller, store, service, vault };
}
if (require.main === module) {
  startDesktop().catch((error) => {
    dialog.showErrorBox(
      "Qwen Audio Studio 启动失败",
      error.message || "请检查本机应用数据目录。",
    );
    app.quit();
  });
}
module.exports = { startDesktop };
