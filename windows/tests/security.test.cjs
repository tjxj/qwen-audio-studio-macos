const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { CredentialVault } = require("../src/core/credentials.cjs");
const { chatEndpoint, requestChat } = require("../src/core/chat.cjs");
const { validateSender, sanitizeState } = require("../src/security.cjs");
const encrypted = {
  isEncryptionAvailable: () => true,
  encryptString: (x) => Buffer.from([...Buffer.from(x)].map((b) => b ^ 73)),
  decryptString: (x) => Buffer.from([...x].map((b) => b ^ 73)).toString(),
};
test("credentials stay encrypted on disk, never in public status, and survive reopening", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "qwen-vault-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const vault = new CredentialVault(dir, encrypted, "win32");
  vault.save({ apiKey: "private-value", workspaceID: "workspace-1" });
  assert.equal(vault.load().apiKey, "private-value");
  assert.equal(
    fs
      .readFileSync(path.join(dir, "credentials.bin"))
      .includes("private-value"),
    false,
  );
  assert.deepEqual(vault.status(), {
    hasAPIKey: true,
    hasChatKey: false,
    encryptionAvailable: true,
  });
  assert.equal(
    new CredentialVault(dir, encrypted, "win32").load().workspaceID,
    "workspace-1",
  );
});
test("credentials refuse insecure fallback and preserve ciphertext when decrypt fails", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "qwen-vault-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const no = new CredentialVault(
    dir,
    { ...encrypted, isEncryptionAvailable: () => false },
    "win32",
  );
  assert.throws(() => no.save({ apiKey: "secret" }), /加密/);
  const linux = new CredentialVault(
    dir,
    { ...encrypted, getSelectedStorageBackend: () => "basic_text" },
    "linux",
  );
  assert.throws(() => linux.save({ apiKey: "secret" }), /加密/);
  fs.writeFileSync(path.join(dir, "credentials.bin"), "broken");
  const bad = new CredentialVault(
    dir,
    {
      ...encrypted,
      decryptString: () => {
        throw Error("secret failure");
      },
    },
    "win32",
  );
  assert.throws(() => bad.load(), /凭据/);
  assert.equal(
    fs.readFileSync(path.join(dir, "credentials.bin"), "utf8"),
    "broken",
  );
});
test("IPC accepts only the exact main frame and local app document", () => {
  const wc = { mainFrame: { url: "file:///app/index.html" } };
  assert.equal(
    validateSender(
      { sender: wc, senderFrame: wc.mainFrame },
      wc,
      "file:///app/index.html",
    ),
    true,
  );
  assert.throws(() =>
    validateSender(
      { sender: wc, senderFrame: { url: "file:///app/index.html" } },
      wc,
      "file:///app/index.html",
    ),
  );
  assert.throws(() =>
    validateSender(
      { sender: wc, senderFrame: wc.mainFrame },
      wc,
      "https://evil.invalid",
    ),
  );
});
test("public snapshot excludes receipts, request payloads, local file paths and credentials", () => {
  const publicState = sanitizeState({
    version: 1,
    draft: { prompt: "text" },
    settings: { outputDirectory: "chosen" },
    tasks: [
      {
        id: "1",
        status: "success",
        receipt: { audioURL: "https://signed.example" },
        snapshot: { references: ["data"] },
        outputPath: "/secret",
        playbackPath: "/secret",
        error: "safe",
        name: "test",
      },
    ],
    references: [
      {
        id: "a",
        name: "voice",
        duration: 1,
        path: "/private/voice.wav",
        contentHash: "hash",
      },
    ],
    chatMessages: [],
    templateFavorites: [],
    customTemplates: [],
  });
  const value = JSON.stringify(publicState);
  for (const hidden of [
    "signed.example",
    "/secret",
    "/private",
    "contentHash",
    "snapshot",
  ])
    assert.equal(value.includes(hidden), false);
  assert.equal(publicState.tasks[0].name, "test");
});
test("chat endpoints reject insecure URLs, credentials, query tokens and unknown paths", () => {
  assert.equal(
    chatEndpoint("https://example.com/v1/"),
    "https://example.com/v1/chat/completions",
  );
  assert.equal(
    chatEndpoint("https://example.com/v1/chat/completions"),
    "https://example.com/v1/chat/completions",
  );
  for (const url of [
    "http://example.com/v1",
    "file:///tmp/key",
    "https://user:pass@example.com/v1",
    "https://example.com/v1?key=token",
    "https://example.com/v1#fragment",
  ])
    assert.throws(() => chatEndpoint(url));
});
test("chat request is single-shot, blocks redirects, limits context and never exposes provider errors", async () => {
  let calls = 0;
  const text = await requestChat({
    baseURL: "https://example.com/v1",
    apiKey: "secret",
    model: "model",
    messages: Array.from({ length: 20 }, (_, i) => ({
      role: "user",
      content: String(i),
    })),
    fetchImpl: async (url, opts) => {
      calls++;
      assert.equal(opts.redirect, "error");
      assert.equal(opts.headers.Authorization, "Bearer secret");
      assert.equal(JSON.parse(opts.body).messages.length, 11);
      return new Response(
        JSON.stringify({ choices: [{ message: { content: "hello" } }] }),
        { status: 200 },
      );
    },
  });
  assert.equal(text, "hello");
  assert.equal(calls, 1);
  await assert.rejects(
    requestChat({
      baseURL: "https://example.com",
      apiKey: "secret",
      model: "model",
      messages: [],
      fetchImpl: async () =>
        new Response("secret and sensitive provider body", { status: 401 }),
    }),
    (e) => !e.message.includes("secret") && e.message.includes("401"),
  );
});
