"use strict";
function validateSender(event, webContents, documentURL) {
  if (
    event.sender !== webContents ||
    event.senderFrame !== webContents.mainFrame ||
    event.senderFrame.url !== documentURL
  )
    throw new Error("拒绝未授权的窗口请求。");
  return true;
}
function pick(source, keys) {
  return Object.fromEntries(
    keys.filter((k) => source[k] !== undefined).map((k) => [k, source[k]]),
  );
}
function sanitizeState(data) {
  return {
    version: data.version,
    draft: structuredClone(data.draft),
    settings: pick(data.settings || {}, [
      "outputDirectory",
      "chatBaseURL",
      "chatModel",
    ]),
    tasks: (data.tasks || []).map((task) => ({
      ...pick(task, [
        "id",
        "name",
        "status",
        "prompt",
        "params",
        "seed",
        "createdAt",
        "duration",
        "error",
        "favorite",
        "trashed",
        "batchID",
        "providerRequestID",
        "size",
        "format",
        "durationVerified",
        "validation",
        "mode",
        "bytes",
      ]),
      draft: task.snapshot?.draft
        ? structuredClone(task.snapshot.draft)
        : undefined,
      canRetryDownload: Boolean(
        task.receipt &&
          ["download_failed", "failed", "interrupted"].includes(task.status),
      ),
    })),
    references: (data.references || []).map((ref) =>
      pick(ref, ["id", "name", "duration", "sampleRate", "channels"]),
    ),
    chatMessages: structuredClone(data.chatMessages || []),
    templateFavorites: structuredClone(data.templateFavorites || []),
    customTemplates: structuredClone(data.customTemplates || []),
  };
}
module.exports = { validateSender, sanitizeState };
