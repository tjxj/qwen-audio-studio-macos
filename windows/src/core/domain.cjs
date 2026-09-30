"use strict";
const { inspectWav } = require("./audio.cjs");

const MODES = Object.freeze(
  [
    ["podcast", "播客"],
    ["advertisement", "广告"],
    ["audiobook", "有声书"],
    ["drama", "广播剧"],
    ["game", "游戏配音"],
    ["narration", "旁白"],
    ["auto", "自定义"],
  ].map(([id, title]) => Object.freeze({ id, title })),
);
const MODE_IDS = new Set(MODES.map((item) => item.id));
const DEFAULT_PARAMS = Object.freeze({
  format: "wav",
  sampleRate: 48000,
  channels: 2,
  volume: 50,
  rate: 1,
  seed: 42,
  enableCBR: false,
  bitRate: 128,
  quality: 5,
  enableAIGCTag: false,
});
const DRAMA_GUIDANCE =
  "创作一段广播剧，保持角色音色一致，按剧情顺序安排台词、环境和动作音效。";
const GUIDANCE = Object.freeze({
  podcast: "创作一段自然播客，保持说话人一致、声场连续和真实对话节奏。",
  advertisement: "创作一段商业广告音频，人声清晰，音效和配乐服务于信息表达。",
  audiobook: DRAMA_GUIDANCE,
  drama: DRAMA_GUIDANCE,
  game: DRAMA_GUIDANCE,
  narration: "创作一段以清晰人声为核心的叙事音频。",
  auto: "根据以下要求创作完整音频。",
});
const CBR_BANDS = new Map([
  [8000, [8, 16, 24, 32, 40, 48, 56, 64]],
  [16000, [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]],
  [24000, [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]],
  [44100, [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]],
  [48000, [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]],
]);
const scalarCount = (text) => Array.from(text).length;
const textValue = (value) => typeof value === "string" && value.isWellFormed();
const record = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const integer = (value, min, max) =>
  Number.isSafeInteger(value) && value >= min && value <= max;
const requireValue = (condition, message) => {
  if (!condition) throw new Error(message);
};
const PARAM_ERROR = "生成参数无效，请检查格式、采样率、数值范围和类型。";
const BINDING_ERROR =
  "音色槽位必须为连续且唯一的 1–3；请补齐缺失槽位，或明确修改脚本和绑定。";

function orderedBindings(bindings) {
  requireValue(Array.isArray(bindings) && bindings.length <= 3, BINDING_ERROR);
  requireValue(
    bindings.every(
      (item) =>
        record(item) &&
        textValue(item.referenceID) &&
        item.referenceID.trim().length > 0 &&
        integer(item.slot, 1, 3),
    ),
    BINDING_ERROR,
  );
  const ordered = bindings
    .map((item) => ({ ...item }))
    .sort((a, b) => a.slot - b.slot);
  requireValue(
    ordered.every((item, index) => item.slot === index + 1) &&
      new Set(ordered.map((item) => item.referenceID)).size === ordered.length,
    BINDING_ERROR,
  );
  return ordered;
}
function validateVoices(text, bindings) {
  for (const [token] of text.matchAll(/@voice[0-9]*/g)) {
    requireValue(
      /^@voice[1-3]$/.test(token),
      `音色标记 ${token} 无效，仅支持 @voice1–@voice3。`,
    );
    requireValue(
      bindings.some((item) => item.slot === Number(token.slice(6))),
      `${token} 缺少对应音色，请绑定原音色或明确修改脚本。`,
    );
  }
}
function validatePrompt(text) {
  requireValue(
    textValue(text) && text.trim().length > 0,
    "请填写有效的创作脚本。",
  );
  requireValue(
    scalarCount(text) <= 3000,
    "编译后的 Prompt 超过 3000 个 Unicode 字符，请缩短脚本。",
  );
}
function compilePrompt({ mode, prompt, bindings = [] } = {}) {
  requireValue(MODE_IDS.has(mode), "创作模式无效。");
  requireValue(
    textValue(prompt) && prompt.trim().length > 0,
    "请填写有效的创作脚本。",
  );
  const source = prompt.trim();
  const ordered = orderedBindings(bindings);
  validateVoices(source, ordered);
  let text = `${GUIDANCE[mode]}\n内容与台词：\n${source}`;
  if (ordered.length)
    text += `\n参考音色：按 @voice1 到 @voice${ordered.length} 的编号使用参考音频。`;
  validatePrompt(text);
  return { text, bindings: ordered, scalarCount: scalarCount(text) };
}

function validateParams(params) {
  requireValue(record(params), PARAM_ERROR);
  const p = params;
  requireValue(
    ["wav", "mp3", "pcm"].includes(p.format) &&
      CBR_BANDS.has(p.sampleRate) &&
      integer(p.channels, 1, 2) &&
      integer(p.volume, 0, 100) &&
      typeof p.rate === "number" &&
      Number.isFinite(p.rate) &&
      p.rate >= 0.5 &&
      p.rate <= 2 &&
      integer(p.seed, 0, Number.MAX_SAFE_INTEGER) &&
      typeof p.enableCBR === "boolean" &&
      integer(p.bitRate, 8, 320) &&
      integer(p.quality, 0, 9) &&
      typeof p.enableAIGCTag === "boolean",
    PARAM_ERROR,
  );
  if (p.format === "mp3" && p.enableCBR)
    requireValue(
      CBR_BANDS.get(p.sampleRate).includes(p.bitRate),
      "MP3 固定码率不支持所选采样率与码率组合。",
    );
  return Object.fromEntries(
    Object.keys(DEFAULT_PARAMS).map((key) => [key, p[key]]),
  );
}
function candidateSeeds(seed, count) {
  requireValue(
    integer(count, 1, 3) &&
      integer(seed, 0, Number.MAX_SAFE_INTEGER - count + 1),
    "候选版本必须为 1–3 个，Seed 必须为可安全递增的非负整数。",
  );
  return Array.from({ length: count }, (_, index) => seed + index);
}
function makeRequest({ prompt, params, seed, references = [] } = {}) {
  const p = validateParams(params);
  validatePrompt(prompt);
  candidateSeeds(seed, 1);
  requireValue(
    Array.isArray(references) && references.length <= 3,
    BINDING_ERROR,
  );
  const bindings = orderedBindings(
    references.map((item) => ({ referenceID: item?.id, slot: item?.slot })),
  );
  validateVoices(prompt, bindings);
  const ordered = [...references].sort((a, b) => a.slot - b.slot);
  const serializedReferences = ordered.map((reference) => {
    const message =
      "参考音色必须为 10 MiB 以内、0–30 秒的完整单声道 PCM16 WAV；请重新选择音频。";
    requireValue(
      Buffer.isBuffer(reference.data) &&
        reference.data.length > 0 &&
        reference.data.length <= 10 * 1024 * 1024 &&
        reference.mimeType === "audio/wav" &&
        typeof reference.duration === "number" &&
        Number.isFinite(reference.duration) &&
        reference.duration > 0 &&
        reference.duration <= 30,
      message,
    );
    const info = inspectWav(reference.data);
    requireValue(
      info.channels === 1 &&
        info.duration > 0 &&
        info.duration <= 30 &&
        Math.abs(info.duration - reference.duration) <= 0.1,
      message,
    );
    return {
      audio_data: `data:audio/wav;base64,${reference.data.toString("base64")}`,
    };
  });
  return {
    model: "qwen-audio-3.1-tts-next",
    input: {
      text_prompt: prompt,
      references: serializedReferences,
      format: p.format,
      sample_rate: p.sampleRate,
      channels: p.channels,
      volume: p.volume,
      rate: p.rate,
      seed,
      enable_cbr: p.enableCBR,
      bit_rate: p.bitRate,
      quality: p.quality,
      enable_aigc_tag: p.enableAIGCTag,
    },
  };
}

const TOKEN_PATTERN = /\{\{\s*([A-Za-z][A-Za-z0-9_]{0,39})\s*\}\}/g;
const sensitive = (value) =>
  /\bsk-[A-Za-z0-9_-]{16,}|data:audio\/[^\s]*|\bllm-[a-z0-9]{8,}|Authorization\s*:\s*Bearer\s+\S+/i.test(
    value,
  );
function validateTemplate(item) {
  const check = (condition, message) =>
    requireValue(condition, message || "模板定义无效。");
  check(record(item));
  check(
    textValue(item.id) &&
      item.id.length > 0 &&
      ["user", "builtin"].includes(item.source ?? "user"),
    "模板标识无效。",
  );
  check(
    textValue(item.name) &&
      item.name.trim().length > 0 &&
      scalarCount(item.name) <= 80,
    "模板名称需要 1–80 字。",
  );
  check(MODE_IDS.has(item.mode), "创作模式无效。");
  check(
    textValue(item.description ?? "") &&
      scalarCount(item.description ?? "") <= 300,
    "模板说明最多 300 字。",
  );
  check(
    textValue(item.prompt_pattern) &&
      item.prompt_pattern.trim().length > 0 &&
      scalarCount(item.prompt_pattern) <= 3000,
    "模板正文需要 1–3000 字。",
  );
  const tags = item.tags ?? [];
  check(
    Array.isArray(tags) &&
      tags.length <= 12 &&
      tags.every((value) => textValue(value) && scalarCount(value) <= 30),
    "最多 12 个标签，每个最多 30 字。",
  );
  check(integer(item.role_count ?? 1, 0, 3), "角色数必须为 0–3。");
  check(
    item.suggested_duration_seconds == null ||
      integer(item.suggested_duration_seconds, 1, 600),
    "建议时长必须为 1–600 秒。",
  );
  const variables = item.variables ?? [];
  check(
    Array.isArray(variables) &&
      variables.length <= 20 &&
      variables.every(record) &&
      new Set(variables.map((value) => value.key)).size === variables.length,
    "变量最多 20 个，名称不可重复。",
  );
  const strings = [
    item.id,
    item.name,
    item.description ?? "",
    item.prompt_pattern,
    ...tags,
  ];
  for (const variable of variables) {
    check(
      textValue(variable.key) &&
        /^[A-Za-z][A-Za-z0-9_]{0,39}$/.test(variable.key),
      "变量名称仅支持英文字母开头的字母、数字和下划线。",
    );
    check(
      textValue(variable.label) && scalarCount(variable.label) <= 80,
      "变量标签最多 80 字。",
    );
    check(["text", "number", "select"].includes(variable.type));
    check(
      variable.required === undefined || typeof variable.required === "boolean",
    );
    check(
      integer(variable.max_length ?? 200, 1, 1000),
      "变量长度限制必须为 1–1000 字。",
    );
    check(
      variable.min == null ||
        (typeof variable.min === "number" && Number.isFinite(variable.min)),
      "数字下限必须为有限数字。",
    );
    check(
      variable.max == null ||
        (typeof variable.max === "number" && Number.isFinite(variable.max)),
      "数字上限必须为有限数字。",
    );
    check(
      (variable.min ?? -Infinity) <= (variable.max ?? Infinity),
      "数字下限不能大于上限。",
    );
    if (variable.type === "select")
      check(
        Array.isArray(variable.options) &&
          integer(variable.options.length, 1, 30) &&
          variable.options.every(
            (value) =>
              textValue(value) && value.length > 0 && scalarCount(value) <= 100,
          ),
        "选项需要 1–30 个有效文本，每个最多 100 字。",
      );
    if (variable.options != null)
      check(
        Array.isArray(variable.options) && variable.options.every(textValue),
      );
    strings.push(
      variable.key,
      variable.label,
      String(variable.default),
      ...(variable.options ?? []),
    );
  }
  check(
    !strings.some(sensitive),
    "模板不能保存 API Key、业务空间标识或音频数据。",
  );
  const tokens = [...item.prompt_pattern.matchAll(TOKEN_PATTERN)].map(
    (match) => match[1],
  );
  const keys = new Set(tokens);
  const remainder = item.prompt_pattern.replace(TOKEN_PATTERN, "");
  check(
    keys.size === variables.length &&
      variables.every((variable) => keys.has(variable.key)) &&
      !remainder.includes("{{") &&
      !remainder.includes("}}"),
    "正文占位符与变量定义必须一致；仅支持 {{变量名}}。",
  );
  return variables;
}
function resolveTemplate(item, variables, values) {
  requireValue(
    record(values) &&
      Object.keys(values).every((key) =>
        variables.some((variable) => variable.key === key),
      ),
    "填写了模板中未定义的变量。",
  );
  const resolved = new Map();
  for (const variable of variables) {
    const value = Object.hasOwn(values, variable.key)
      ? values[variable.key]
      : variable.default;
    const invalid = `请为“${variable.label}”填写有效的${variable.type === "number" ? "范围内数字" : "文本或选项"}。`;
    if (variable.type === "number") {
      requireValue(
        typeof value === "number" &&
          Number.isFinite(value) &&
          value >= (variable.min ?? -Infinity) &&
          value <= (variable.max ?? Infinity),
        invalid,
      );
    } else {
      requireValue(
        textValue(value) &&
          scalarCount(value) <= (variable.max_length ?? 200) &&
          (!(variable.required ?? true) || value.trim().length > 0) &&
          (variable.type !== "select" || variable.options.includes(value)),
        invalid,
      );
      requireValue(
        !value.includes("{{") && !value.includes("}}") && !sensitive(value),
        "变量不能包含模板表达式或敏感内容。",
      );
    }
    const display =
      typeof value === "number" && Number.isInteger(value)
        ? Object.is(value, -0)
          ? "-0"
          : BigInt(value).toString()
        : String(value);
    resolved.set(variable.key, display);
  }
  // Callback replacements preserve dollar signs and backslashes literally.
  const prompt = item.prompt_pattern.replace(TOKEN_PATTERN, (_, key) =>
    resolved.get(key),
  );
  // Template preview has no real audio yet; validate slot syntax without fabricating persisted references.
  const slots = [...prompt.matchAll(/@voice([1-3])/g)].map((match) =>
    Number(match[1]),
  );
  const bindings = Array.from(
    { length: Math.max(0, ...slots) },
    (_, index) => ({ referenceID: `validation-${index}`, slot: index + 1 }),
  );
  compilePrompt({ mode: item.mode, prompt, bindings });
  return prompt;
}
function expandTemplate(template, values = {}) {
  const variables = validateTemplate(template);
  // An override may never conceal an invalid or sensitive default in a saved template.
  resolveTemplate(template, variables, {});
  const prompt = resolveTemplate(template, variables, values);
  return { name: template.name, mode: template.mode, prompt };
}
function parseScript(text) {
  if (!textValue(text)) return null;
  const blocks = [...text.matchAll(/```(?:qwen-script)?\s*\n?([\s\S]*?)```/g)];
  for (const match of blocks.reverse()) {
    let name = "未命名灵感脚本";
    let mode = "podcast";
    const script = [];
    for (const line of match[1].trim().split(/\r\n|[\n\r\u0085\u2028\u2029]/)) {
      const trimmed = line.trim();
      if (/^\[标题\][:：]/.test(trimmed)) {
        const title = trimmed.replace(/\[标题\][:：]/g, "").trim();
        if (title) name = title;
      } else if (/^\[模式\][:：]/.test(trimmed)) {
        const value = trimmed.replace(/\[模式\][:：]/g, "").trim();
        if (value.includes("播客")) mode = "podcast";
        else if (value.includes("广告")) mode = "advertisement";
        else if (value.includes("旁白") || value.includes("解说"))
          mode = "narration";
        else if (value.includes("广播剧")) mode = "drama";
        else if (value.includes("游戏")) mode = "game";
        else if (value.includes("有声书")) mode = "audiobook";
        else mode = "auto";
      } else script.push(line);
    }
    const prompt = script.join("\n").trim();
    if (prompt) return { name, mode, prompt };
  }
  return null;
}

module.exports = {
  MODES,
  DEFAULT_PARAMS,
  compilePrompt,
  validateParams,
  makeRequest,
  candidateSeeds,
  expandTemplate,
  parseScript,
};
