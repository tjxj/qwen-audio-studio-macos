const { test } = require("node:test");
const assert = require("node:assert/strict");
const { verifyPackageFiles } = require("../scripts/package-validation.cjs");
const required = [
  "/src/main.cjs",
  "/src/preload.cjs",
  "/src/renderer/index.html",
  "/src/renderer/app.js",
  "/resources/templates.json",
];
test("package checks accept actual Windows asar separators and POSIX separators", () => {
  assert.doesNotThrow(() => verifyPackageFiles(required));
  assert.doesNotThrow(() =>
    verifyPackageFiles(required.map((x) => x.replaceAll("/", "\\"))),
  );
});
test("package checks reject missing production files and test/private content on both platforms", () => {
  assert.throws(() => verifyPackageFiles(required.slice(1)), /Missing/);
  for (const extra of [
    "/tests/fake.cjs",
    "\\tests\\fake.cjs",
    "/credentials.bin",
  ])
    assert.throws(() => verifyPackageFiles([...required, extra]), /Private/);
});
