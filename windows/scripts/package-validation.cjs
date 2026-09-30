"use strict";
/** @electron/asar uses the host's path.join when listing files. */
function verifyPackageFiles(entries) {
  const files = entries.map((file) => file.replaceAll("\\", "/"));
  for (const required of [
    "/src/main.cjs",
    "/src/preload.cjs",
    "/src/renderer/index.html",
    "/src/renderer/app.js",
    "/resources/templates.json",
  ])
    if (!files.includes(required))
      throw new Error(`Missing packaged file ${required}`);
  if (
    files.some(
      (file) => file.startsWith("/tests/") || file.includes("credentials.bin"),
    )
  )
    throw new Error("Private or test data in package");
  return files;
}
module.exports = { verifyPackageFiles };
