"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { Store } = require("../src/core/store.cjs");
const { CredentialVault } = require("../src/core/credentials.cjs");
const { StudioController } = require("../src/controller.cjs");
const { GenerationService } = require("../src/core/generation.cjs");
const { DEFAULT_PARAMS } = require("../src/core/domain.cjs");
const { wrapPCM } = require("../src/core/audio.cjs");
const encrypted = {
  isEncryptionAvailable: () => true,
  encryptString: (x) => Buffer.from(x).map((b) => b ^ 73),
  decryptString: (x) =>
    Buffer.from(x)
      .map((b) => b ^ 73)
      .toString(),
};
function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "qwen-review-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const store = new Store(directory);
  store.load();
  const vault = new CredentialVault(directory, encrypted, "win32");
  vault.save({
    apiKey: "fake-audio-key",
    workspaceID: "fake-workspace",
    chatAPIKey: "old-provider-fake-key",
    chatEndpoint: "https://old.invalid/v1/chat/completions",
  });
  store.update((s) => {
    s.settings.chatBaseURL = "https://old.invalid/v1";
    s.settings.chatModel = "model";
  });
  const calls = [];
  const controller = new StudioController({
    store,
    vault,
    directory,
    service: { isBusy: false },
    dialog: {},
    shell: {},
    templates: [],
    chatClient: async (args) => {
      calls.push(args);
      return "fake response";
    },
  });
  return { directory, store, vault, controller, calls };
}

test("review: failed settings commit must not send a new provider key to the old provider", async (t) => {
  const { store, vault, controller, calls } = fixture(t);
  // Inject failure only at the actual settings database replacement; the credential
  // vault executes its real encrypted-file save, flush and rename successfully.
  const original = fs.renameSync;
  fs.renameSync = function (source, target) {
    if (target === store.filePath)
      throw new Error("simulated database rename failure");
    return original.apply(this, arguments);
  };
  try {
    await assert.rejects(
      controller.saveSettings({
        chatBaseURL: "https://new.invalid/v1",
        chatAPIKey: "new-provider-fake-key",
      }),
      /rename failure/,
    );
  } finally {
    fs.renameSync = original;
  }
  assert.equal(store.snapshot().settings.chatBaseURL, "https://old.invalid/v1");
  assert.equal(
    new Store(store.directory).load().settings.chatBaseURL,
    "https://old.invalid/v1",
  );
  try {
    await controller.chat({ text: "Test after failed save" });
  } catch {}
  assert.equal(
    calls.some(
      (c) =>
        c.baseURL === "https://old.invalid/v1" &&
        c.apiKey === "new-provider-fake-key",
    ),
    false,
    "new provider key was transmitted to old provider after failed settings save",
  );
});

test("review: restarting an in-flight paid request must preserve explicit uncertain billing state", (t) => {
  const { store } = fixture(t);
  store.update((s) =>
    s.tasks.push({
      id: "request-crash",
      status: "requesting",
      createdAt: new Date().toISOString(),
      submissionID: "test-submission",
    }),
  );
  const recovered = new Store(store.directory).load().tasks[0];
  assert.equal(
    recovered.status,
    "uncertain",
    "requesting recovery becomes indistinguishable from unsubmitted interrupted work",
  );
  assert.match(recovered.error, /费用|收费|可能/);
});

test("review: post-durable-write failure never sends paid request", async (t) => {
  const { directory, store, vault } = fixture(t);
  const output = path.join(directory, "output");
  fs.mkdirSync(output);
  let paidCalls = 0;
  const service = new GenerationService({
    store,
    credentials: () => vault.load(),
    outputDirectory: output,
    provider: {
      async synthesize() {
        paidCalls++;
        throw Error("should not run");
      },
    },
  });
  const draft = {
    name: "test",
    mode: "podcast",
    prompt: "hello",
    params: { ...DEFAULT_PARAMS },
    bindings: [],
  };
  const plan = service.preflight(draft, 3);
  const original = fs.renameSync;
  let commits = 0;
  fs.renameSync = function (source, target) {
    if (target === store.filePath && ++commits === 2)
      throw new Error("request-state save failure");
    return original.apply(this, arguments);
  };
  try {
    await assert.rejects(service.submit(plan.token), /save failure/);
  } finally {
    fs.renameSync = original;
  }
  assert.equal(paidCalls, 0);
  assert.equal(new Store(directory).load().tasks.length, 3);
  const reopened = new GenerationService({
    store: new Store(directory),
    credentials: () => vault.load(),
    outputDirectory: output,
    provider: {
      async synthesize() {
        paidCalls++;
        throw Error("should not run");
      },
    },
  });
  await reopened.submit(plan.token);
  assert.equal(paidCalls, 0);
});

test("review: undecodable MP3 must not be presented as an ordinary completed verified asset", async (t) => {
  const { directory, store, vault } = fixture(t);
  const output = path.join(directory, "output");
  fs.mkdirSync(output);
  // Four correctly sized MPEG1 Layer III headers with deliberately invalid side
  // information (all ones => big_values > 288); ffmpeg -xerror rejects this data.
  const frame = Buffer.alloc(417, 0xff);
  Buffer.from([0xff, 0xfb, 0x90, 0x00]).copy(frame);
  const corrupt = Buffer.concat([frame, frame, frame, frame]);
  const provider = {
    synthesize: async () => ({
      requestID: "fake-mp3",
      audioURL: "https://fake.invalid/audio",
      expiresAt: Date.now() / 1000 + 60,
    }),
    download: async () => corrupt,
  };
  const service = new GenerationService({
    store,
    credentials: () => vault.load(),
    outputDirectory: output,
    provider,
  });
  const draft = {
    name: "test",
    mode: "podcast",
    prompt: "hello",
    params: { ...DEFAULT_PARAMS, format: "mp3", sampleRate: 44100 },
    bindings: [],
  };
  const result = await service.submit(service.preflight(draft).token);
  const publicTask = require("../src/security.cjs").sanitizeState(
    store.snapshot(),
  ).tasks[0];
  if (result.tasks[0].status === "success") {
    assert.equal(
      publicTask.durationVerified,
      false,
      "public result hides the lack of decode verification",
    );
    assert.match(
      publicTask.validation,
      /未进行解码|未验证|未解码/,
      "unverified audio requires an explicit user-visible qualification",
    );
  }
});

test("review: normal endpoint-bound chat still works and changing providers does not break the positive path", async (t) => {
  const { controller, calls } = fixture(t);
  await controller.chat({ text: "Old endpoint test" });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].apiKey, "old-provider-fake-key");
  await controller.saveSettings({
    chatBaseURL: "https://new.invalid/v1/",
    chatAPIKey: "new-provider-fake-key",
  });
  await controller.chat({ text: "New endpoint test" });
  assert.equal(calls.length, 2);
  assert.equal(calls[1].baseURL, "https://new.invalid/v1");
  assert.equal(calls[1].apiKey, "new-provider-fake-key");
});
