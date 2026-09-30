"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const crypto = require("node:crypto");
const { Store } = require("../src/core/store.cjs");
const { GenerationService } = require("../src/core/generation.cjs");
const { DEFAULT_PARAMS } = require("../src/core/domain.cjs");
const { wrapPCM } = require("../src/core/audio.cjs");
function setup(t, overrides = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "qwen-generation-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const store = new Store(path.join(dir, "store"));
  store.load();
  const out = path.join(dir, "output");
  fs.mkdirSync(out);
  store.update((data) => {
    data.settings.outputDirectory = out;
  });
  const calls = [];
  const downloads = [];
  const wav = wrapPCM(Buffer.alloc(48000 * 2 * 2), {
    sampleRate: 48000,
    channels: 2,
  });
  const provider = {
    async synthesize(input) {
      calls.push(input);
      return {
        requestID: "request-" + calls.length,
        audioURL: "https://cdn.test/file?secret=x",
        expiresAt: Date.now() / 1000 + 3600,
      };
    },
    async download(input) {
      downloads.push(input);
      return wav;
    },
    ...overrides.provider,
  };
  const service = new GenerationService({
    store,
    credentials: () => ({
      workspaceID: "workspace",
      apiKey: "do-not-persist-key",
    }),
    provider,
    outputDirectory: () => store.snapshot().settings.outputDirectory,
    ...overrides,
    provider,
  });
  const draft = {
    name: "测试作品",
    mode: "podcast",
    prompt: "你好，欢迎收听。",
    bindings: [],
    params: { ...DEFAULT_PARAMS },
  };
  return { dir, store, out, calls, downloads, provider, service, draft, wav };
}

test("preflight exposes exact calls, seeds and no signed URL or key", (t) => {
  const { service, draft } = setup(t);
  const plan = service.preflight(draft, 3);
  assert.equal(plan.calls, 3);
  assert.deepEqual(plan.seeds, [42, 43, 44]);
  assert.match(plan.prompt, /你好/);
  assert.equal(plan.params.format, "wav");
  assert.doesNotMatch(JSON.stringify(plan), /do-not-persist-key|secret=x/);
});

test("one confirmed token makes one immutable durable batch and duplicate submits share the same promise", async (t) => {
  const { service, draft, store, out, calls } = setup(t);
  const plan = service.preflight(draft, 2);
  draft.prompt = "changed";
  plan.prompt = "tampered";
  plan.params.seed = 900;
  const promise = service.submit(plan.token);
  const duplicate = service.submit(plan.token);
  assert.equal(promise, duplicate);
  assert.equal(service.isBusy, true);
  const result = await promise;
  assert.equal(calls.length, 2);
  assert.equal(service.isBusy, false);
  assert.ok(result.tasks.every((task) => task.status === "success"));
  assert.deepEqual(
    calls.map((call) => call.body.input.seed),
    [42, 43],
  );
  assert.ok(
    calls.every((call) => call.body.input.text_prompt.includes("你好")),
  );
  const task = result.tasks[0];
  assert.equal(task.outputDirectory, out);
  assert.match(task.requestHash, /^[a-f0-9]{64}$/);
  assert.equal(
    fs.readFileSync(task.outputPath).subarray(0, 4).toString(),
    "RIFF",
  );
  assert.ok(fs.existsSync(path.join(task.directory, "prompt.txt")));
  assert.ok(fs.existsSync(path.join(task.directory, "report.json")));
  assert.doesNotMatch(
    fs.readFileSync(store.filePath, "utf8"),
    /do-not-persist-key/,
  );
  assert.notEqual(result.tasks[0].directory, result.tasks[1].directory);
  assert.equal(service.submit(plan.token), promise);
  await service.submit(plan.token);
  assert.equal(calls.length, 2);
});

test("snapshot and requesting state are durable before paid POST", async (t) => {
  const { service, draft, store, provider } = setup(t);
  provider.synthesize = async (input) => {
    const raw = JSON.parse(fs.readFileSync(store.filePath));
    assert.equal(raw.tasks[0].status, "requesting");
    assert.ok(raw.tasks[0].snapshot.prompt.includes("你好"));
    assert.match(raw.tasks[0].requestHash, /^[a-f0-9]{64}$/);
    return {
      requestID: "id",
      audioURL: "https://cdn.test/audio",
      expiresAt: Date.now() / 1000 + 60,
    };
  };
  const result = await service.submit(service.preflight(draft, 1).token);
  assert.equal(result.tasks[0].status, "success");
});

test("disk commit failure prevents every paid POST", async (t) => {
  const { service, draft, store, calls } = setup(t);
  const plan = service.preflight(draft, 1);
  store.update = () => {
    throw new Error("disk full");
  };
  await assert.rejects(service.submit(plan.token), /disk full/);
  assert.equal(calls.length, 0);
  assert.equal(service.isBusy, false);
});

test("unknown generation error is uncertain, redacted, and not replayed after restart", async (t) => {
  const { service, draft, store, provider, calls } = setup(t);
  provider.synthesize = async (input) => {
    calls.push(input);
    throw new Error("do-not-persist-key https://signed.test/?private");
  };
  const plan = service.preflight(draft, 1);
  const result = await service.submit(plan.token);
  assert.equal(result.tasks[0].status, "uncertain");
  assert.doesNotMatch(result.tasks[0].error, /do-not-persist-key|signed.test/);
  const restartedStore = new Store(store.directory);
  restartedStore.load();
  const restarted = new GenerationService({
    store: restartedStore,
    credentials: () => ({ workspaceID: "workspace", apiKey: "key" }),
    provider,
  });
  const existing = await restarted.submit(plan.token);
  assert.equal(existing.tasks[0].status, "uncertain");
  assert.equal(calls.length, 1);
});

test("download failure retains receipt and explicit retry never sends another paid POST", async (t) => {
  const { service, draft, provider, calls, downloads, wav } = setup(t);
  provider.download = async (input) => {
    downloads.push(input);
    throw new Error("download unavailable https://secret");
  };
  const first = await service.submit(service.preflight(draft, 1).token);
  assert.equal(first.tasks[0].status, "download_failed");
  assert.ok(first.tasks[0].receipt);
  provider.download = async (input) => {
    downloads.push(input);
    return wav;
  };
  const retry = service.retryDownload(first.tasks[0].id);
  assert.equal(service.retryDownload(first.tasks[0].id), retry);
  const result = await retry;
  assert.equal(result.status, "success");
  assert.equal(calls.length, 1);
  assert.equal(downloads.length, 2);
});

test("expired and canceled preflights cannot submit", async (t) => {
  let now = Date.now();
  const { service, draft, calls } = setup(t, { now: () => now });
  const expired = service.preflight(draft, 1);
  now += 600001;
  assert.throws(() => service.submit(expired.token), /过期|失效/);
  const canceled = service.preflight(draft, 1);
  service.cancelPreflight(canceled.token);
  assert.throws(() => service.submit(canceled.token), /过期|失效/);
  assert.equal(calls.length, 0);
});

test("reference buffers are validated and snapshotted from trusted library paths", async (t) => {
  const { service, draft, store, calls } = setup(t);
  const referenceDir = path.join(store.directory, "references");
  fs.mkdirSync(referenceDir);
  const audio = wrapPCM(Buffer.alloc(16000 * 2), {
    sampleRate: 16000,
    channels: 1,
  });
  const refPath = path.join(referenceDir, "ref.wav");
  fs.writeFileSync(refPath, audio);
  const ref = {
    id: "ref",
    name: "我的声音.wav",
    path: refPath,
    mimeType: "audio/wav",
    duration: 1,
    contentHash: crypto.createHash("sha256").update(audio).digest("hex"),
  };
  store.update((data) => data.references.push(ref));
  draft.bindings = [{ referenceID: "ref", slot: 1, alias: "主持人" }];
  const plan = service.preflight(draft, 1);
  assert.deepEqual(plan.references, [
    { id: "ref", slot: 1, name: "我的声音.wav", duration: 1 },
  ]);
  fs.writeFileSync(refPath, Buffer.from("changed after confirmation"));
  const result = await service.submit(plan.token);
  assert.equal(result.tasks[0].status, "success");
  const transmitted = calls[0].body.input.references[0].audio_data;
  assert.equal(
    transmitted,
    "data:audio/wav;base64," + audio.toString("base64"),
  );
  assert.throws(() => service.preflight(draft, 1));
});

test("reference paths outside private library and hash changes fail before network", (t) => {
  const { service, draft, store, out } = setup(t);
  const file = path.join(out, "unsafe.wav");
  const bytes = wrapPCM(Buffer.alloc(16000 * 2), {
    sampleRate: 16000,
    channels: 1,
  });
  fs.writeFileSync(file, bytes);
  store.update((data) =>
    data.references.push({
      id: "ref",
      name: "x",
      path: file,
      mimeType: "audio/wav",
      duration: 1,
      contentHash: crypto.createHash("sha256").update(bytes).digest("hex"),
    }),
  );
  draft.bindings = [{ referenceID: "ref", slot: 1 }];
  assert.throws(() => service.preflight(draft, 1), /参考/);
});

test("PCM output gets a playable WAV companion and malformed WAV never becomes success", async (t) => {
  const good = setup(t);
  good.draft.params.format = "pcm";
  good.provider.download = async () => Buffer.alloc(48000 * 2 * 2);
  const result = await good.service.submit(
    good.service.preflight(good.draft, 1).token,
  );
  assert.equal(result.tasks[0].status, "success");
  assert.match(result.tasks[0].outputPath, /audio.pcm$/);
  assert.match(result.tasks[0].playbackPath, /playback.wav$/);
  const bad = setup(t);
  bad.provider.download = async () => Buffer.from("RIFFnot-a-real-wave");
  const failed = await bad.service.submit(
    bad.service.preflight(bad.draft, 1).token,
  );
  assert.equal(failed.tasks[0].status, "download_failed");
  assert.equal(failed.tasks[0].outputPath, undefined);
});

function framedMP3Fixture() {
  // Frame structure fixture only. It is NOT a decodable MP3, and decoder
  // injection tests below exercise orchestration rather than real decoding.
  const frame = Buffer.alloc(417);
  Buffer.from([0xff, 0xfb, 0x90, 0x00]).copy(frame);
  return Buffer.concat([frame, frame]);
}

test("structurally framed MP3 cannot succeed without an actual decoder", async (t) => {
  const { service, draft, provider } = setup(t);
  draft.params = { ...draft.params, format: "mp3", sampleRate: 44100 };
  provider.download = async () => framedMP3Fixture();
  const result = await service.submit(service.preflight(draft, 1).token);
  assert.equal(result.tasks[0].status, "download_failed");
  assert.equal(result.tasks[0].outputPath, undefined);
});

test("decoder rejection prevents structurally framed garbage from becoming successful MP3", async (t) => {
  let decoded = false;
  const { service, draft, provider } = setup(t, {
    decodeAudio: async () => {
      decoded = true;
      throw new Error("decoder rejected malformed compressed data");
    },
  });
  draft.params = { ...draft.params, format: "mp3", sampleRate: 44100 };
  provider.download = async () => framedMP3Fixture();
  const result = await service.submit(service.preflight(draft, 1).token);
  assert.equal(decoded, true);
  assert.equal(result.tasks[0].status, "download_failed");
  assert.equal(result.tasks[0].outputPath, undefined);
});

test("injected decoder result controls verified MP3 duration and report metadata", async (t) => {
  const bytes = framedMP3Fixture();
  let received;
  const { service, draft, provider } = setup(t, {
    decodeAudio: async (input) => {
      received = input;
      return { duration: 1.25 };
    },
  });
  draft.params = { ...draft.params, format: "mp3", sampleRate: 44100 };
  provider.download = async () => bytes;
  const result = await service.submit(service.preflight(draft, 1).token);
  const task = result.tasks[0];
  assert.deepEqual(received.data, bytes);
  assert.deepEqual(received.params, draft.params);
  assert.equal(received.mode, "podcast");
  assert.equal(task.status, "success");
  assert.equal(task.duration, 1.25);
  assert.equal(task.durationVerified, true);
  assert.equal(task.validation, "已解码验证 MP3 与时长");
  const report = JSON.parse(
    fs.readFileSync(path.join(task.directory, "report.json")),
  );
  assert.equal(report.duration, 1.25);
  assert.equal(report.durationVerified, true);
});

test("decoder duration must be finite positive and within the mode limit", async (t) => {
  for (const duration of [undefined, NaN, Infinity, 0, -1, 240.01, "1"]) {
    const { service, draft, provider } = setup(t, {
      decodeAudio: async () => ({ duration }),
    });
    draft.params = { ...draft.params, format: "mp3", sampleRate: 44100 };
    provider.download = async () => framedMP3Fixture();
    const result = await service.submit(service.preflight(draft, 1).token);
    assert.equal(result.tasks[0].status, "download_failed", String(duration));
  }
  const { service, draft, provider } = setup(t, {
    decodeAudio: async () => ({ duration: 120.01 }),
  });
  draft.mode = "narration";
  draft.params = { ...draft.params, format: "mp3", sampleRate: 44100 };
  provider.download = async () => framedMP3Fixture();
  const result = await service.submit(service.preflight(draft, 1).token);
  assert.equal(result.tasks[0].status, "download_failed");
});

test("malformed MP3 headers are rejected before calling the decoder", async (t) => {
  let decoded = false;
  const { service, draft, provider } = setup(t, {
    decodeAudio: async () => {
      decoded = true;
      return { duration: 1 };
    },
  });
  draft.params.format = "mp3";
  provider.download = async () => Buffer.from("ID3just text, no MPEG frames");
  const result = await service.submit(service.preflight(draft, 1).token);
  assert.equal(result.tasks[0].status, "download_failed");
  assert.equal(decoded, false);
});

test("trashed references cannot be uploaded even while retained on disk", (t) => {
  const { service, draft, store } = setup(t);
  const referenceDir = path.join(store.directory, "references");
  fs.mkdirSync(referenceDir);
  const bytes = wrapPCM(Buffer.alloc(16000 * 2), {
    sampleRate: 16000,
    channels: 1,
  });
  const file = path.join(referenceDir, "retained.wav");
  fs.writeFileSync(file, bytes);
  store.update((data) =>
    data.references.push({
      id: "ref",
      name: "x",
      path: file,
      mimeType: "audio/wav",
      duration: 1,
      contentHash: crypto.createHash("sha256").update(bytes).digest("hex"),
      trashed: true,
    }),
  );
  draft.bindings = [{ referenceID: "ref", slot: 1 }];
  assert.throws(() => service.preflight(draft, 1), /参考/);
});

test("missing output directory before a queued candidate becomes failed without posting it", async (t) => {
  const { service, draft, provider, calls, out } = setup(t);
  provider.download = async () => {
    fs.rmSync(out, { recursive: true, force: true });
    throw new Error("directory removed");
  };
  const result = await service.submit(service.preflight(draft, 2).token);
  assert.equal(calls.length, 1);
  assert.deepEqual(
    result.tasks.map((task) => task.status),
    ["download_failed", "failed"],
  );
});

test("changed workspace identity requires a fresh confirmation before any paid POST", async (t) => {
  let workspaceID = "workspace";
  const { service, draft, calls } = setup(t, {
    credentials: () => ({ workspaceID, apiKey: "key" }),
  });
  const plan = service.preflight(draft, 1);
  workspaceID = "another-workspace";
  await assert.rejects(service.submit(plan.token), /凭据已变化/);
  assert.equal(calls.length, 0);
});

test("confirmation expiry while one candidate runs prevents later paid candidates", async (t) => {
  let now = Date.now();
  const { service, draft, provider, calls, wav } = setup(t, { now: () => now });
  provider.download = async () => {
    now += 600001;
    return wav;
  };
  const result = await service.submit(service.preflight(draft, 3).token);
  assert.equal(calls.length, 1);
  assert.deepEqual(
    result.tasks.map((task) => task.status),
    ["success", "failed", "failed"],
  );
});

test("provider request ID survives download failure and successful output records byte count", async (t) => {
  const { service, draft, provider, wav } = setup(t);
  provider.download = async () => {
    throw new Error("offline");
  };
  const initial = await service.submit(service.preflight(draft, 1).token);
  assert.equal(initial.tasks[0].providerRequestID, "request-1");
  provider.download = async () => wav;
  const task = await service.retryDownload(initial.tasks[0].id);
  assert.equal(task.providerRequestID, "request-1");
  assert.equal(task.bytes, wav.length);
});
