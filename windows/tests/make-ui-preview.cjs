// Test-only fixture, safe to open as file:// without an HTTP server or paid API.
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
const source = fs.readFileSync(path.join(__dirname, "ui.spec.cjs"), "utf8");
const initialText = source.slice(
  source.indexOf("const initial ="),
  source.indexOf("async function launch"),
);
const context = { templates: require("../resources/templates.json") };
vm.createContext(context);
vm.runInContext(initialText + ";globalThis.value=initial;", context);
const start =
  source.indexOf("await page.addInitScript(") +
  "await page.addInitScript(".length;
const end = source.indexOf("},{initial,overrides});", start) + 1;
const callback = source.slice(start, end);
fs.writeFileSync(
  path.join(__dirname, "ui-preview-bridge.js"),
  "// Generated test-only fixture: no credentials, no network.\n(" +
    callback +
    ")(" +
    JSON.stringify({ initial: context.value, overrides: {} }) +
    ");\n",
);
const html = fs
  .readFileSync(path.join(__dirname, "../src/renderer/index.html"), "utf8")
  .replace('href="styles.css"', 'href="../src/renderer/styles.css"')
  .replace(
    '<script src="audio.js" defer></script>',
    '<script src="ui-preview-bridge.js" defer></script>\n  <script src="../src/renderer/audio.js" defer></script>',
  )
  .replace('src="app.js"', 'src="../src/renderer/app.js"');
fs.writeFileSync(path.join(__dirname, "ui-preview.html"), html);

fs.appendFileSync(
  path.join(__dirname, "ui-preview-bridge.js"),
  `
// Interactive preview completes only its mocked local task.
const fixtureSubmit = window.studio.submit;
window.studio.submit = async token => {
  await fixtureSubmit(token);
  const snapshot = await window.studio.bootstrap();
  window.mockState({tasks:snapshot.tasks.map(task=>({...task,status:'success',duration:0.25,durationVerified:true,validation:'测试夹具 · 本地合成音频',draft:structuredClone(snapshot.draft)}))});
  return {accepted:true};
};
`,
);
