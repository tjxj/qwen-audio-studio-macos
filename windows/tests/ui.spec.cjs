const { test, expect } = require("@playwright/test");
const templates = require("../resources/templates.json");
const initial = {
  draft: {
    name: "雨夜里的慢生活",
    mode: "podcast",
    prompt:
      "【场景】雨夜，窗边的一盏灯。\n【对白：讲述者】今晚，不必急着给生活一个答案。",
    params: {
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
    },
    bindings: [],
  },
  settings: {
    workspaceID: "workspace-demo",
    outputDirectory: "C:\\Music\\Qwen",
    chatBaseURL: "https://api.example.com/v1",
    chatModel: "writer",
  },
  tasks: [],
  references: [],
  templates,
  customTemplates: [],
  templateFavorites: [],
  chatMessages: [],
  credentials: { hasAPIKey: true, hasChatKey: true, encryptionAvailable: true },
  version: "0.1.0",
};
async function launch(page, overrides = {}) {
  await page.addInitScript(
    ({ initial, overrides }) => {
      let state = { ...initial, ...overrides };
      const listeners = [];
      window.calls = [];
      const clone = (v) => structuredClone(v);
      const emit = () => listeners.forEach((fn) => fn(clone(state)));
      window.mockState = (patch) => {
        Object.assign(state, patch);
        emit();
      };
      window.studio = {
        bootstrap: async () => clone(state),
        onBeforeClose: (fn) => {
          window.beforeCloseCallback = fn;
          return () => {};
        },
        cancelPreflight: async (token) => {
          window.calls.push(["cancelPreflight", token]);
        },
        onState: (fn) => {
          listeners.push(fn);
          return () => {};
        },
        saveDraft: async (draft) => {
          window.calls.push(["saveDraft", clone(draft)]);
          state.draft = clone(draft);
          return clone(draft);
        },
        saveSettings: async (data) => {
          window.calls.push(["saveSettings", data]);
          state.settings = { ...state.settings, ...data };
          emit();
          return clone(state);
        },
        chooseOutputDirectory: async () => {
          state.settings.outputDirectory = "C:\\Exports";
          emit();
          return "C:\\Exports";
        },
        preflight: async (data) => {
          window.calls.push(["preflight", clone(data)]);
          return {
            token: "confirmed-token",
            prompt: data.draft.prompt,
            params: data.draft.params,
            seeds: Array.from({ length: data.candidates }, (_, i) => 42 + i),
            references: data.draft.bindings.map((b) => ({
              ...b,
              name: "voice.wav",
              duration: 12,
            })),
            outputDirectory: state.settings.outputDirectory,
            calls: data.candidates,
          };
        },
        submit: async (token) => {
          window.calls.push(["submit", token]);
          state.tasks = [
            {
              id: "task-1",
              name: state.draft.name,
              status: "generating",
              prompt: state.draft.prompt,
              params: state.draft.params,
              seed: 42,
              createdAt: new Date().toISOString(),
            },
          ];
          emit();
          return { accepted: true };
        },
        expandTemplate: async ({ id, values }) => {
          const t = state.templates.find((x) => x.id === id);
          return {
            name: t.name,
            mode: t.mode,
            prompt: t.prompt_pattern.replace(
              /\{\{(\w+)\}\}/g,
              (_, key) => values[key] ?? "",
            ),
          };
        },
        favoriteTemplate: async (data) => {
          state.templateFavorites = data.favorite
            ? [...state.templateFavorites, data.id]
            : state.templateFavorites.filter((id) => id !== data.id);
          emit();
        },
        saveTemplate: async (data) => {
          window.calls.push(["saveTemplate", data]);
          state.customTemplates.push({
            ...data,
            id: "custom-1",
            source: "user",
          });
          emit();
        },
        removeTemplate: async () => {},
        updateTask: async (data) => {
          window.calls.push(["updateTask", data]);
          Object.assign(
            state.tasks.find((t) => t.id === data.id),
            data,
          );
          emit();
        },
        retryDownload: async (id) => window.calls.push(["retryDownload", id]),
        revealTask: async (id) => window.calls.push(["revealTask", id]),
        exportTask: async (id) => {
          window.calls.push(["exportTask", id]);
          return "C:\\export.wav";
        },
        chat: async ({ text }) => {
          state.chatMessages = [
            { role: "user", content: text },
            {
              role: "assistant",
              content:
                "<img src=x onerror=alert(1)>\n```qwen-script\n[标题]: 清晨\n[模式]: 旁白\n【对白：旁白】清晨的风。\n```",
            },
          ];
          emit();
          return { messages: state.chatMessages };
        },
        clearChat: async () => {
          state.chatMessages = [];
          emit();
        },
        pickReference: async () => {
          const count = 8000 * 40,
            bytes = new Uint8Array(44 + count * 2),
            view = new DataView(bytes.buffer);
          for (const [offset, text] of [
            [0, "RIFF"],
            [8, "WAVE"],
            [12, "fmt "],
            [36, "data"],
          ])
            for (let i = 0; i < text.length; i++)
              view.setUint8(offset + i, text.charCodeAt(i));
          view.setUint32(4, bytes.length - 8, true);
          view.setUint32(16, 16, true);
          view.setUint16(20, 1, true);
          view.setUint16(22, 1, true);
          view.setUint32(24, 8000, true);
          view.setUint32(28, 16000, true);
          view.setUint16(32, 2, true);
          view.setUint16(34, 16, true);
          view.setUint32(40, count * 2, true);
          for (let i = 0; i < count; i++)
            view.setInt16(
              44 + i * 2,
              Math.sin((i / 8000) * 440 * Math.PI * 2) * 6000,
              true,
            );
          return { name: "本地正弦波测试.wav", data: bytes };
        },
        saveReference: async (data) => {
          window.calls.push(["saveReference", data]);
          const view = new DataView(data.data.buffer);
          const ref = {
            id: "ref-new",
            name: data.name,
            duration: view.getUint32(40, true) / view.getUint32(28, true),
          };
          state.references.push(ref);
          emit();
          return ref;
        },
        removeReference: async (id) => {
          state.references = state.references.filter((r) => r.id !== id);
          emit();
        },
        readAudio: async () => {
          const bytes = new Uint8Array(4044),
            v = new DataView(bytes.buffer);
          for (const [o, s] of [
            [0, "RIFF"],
            [8, "WAVE"],
            [12, "fmt "],
            [36, "data"],
          ])
            for (let i = 0; i < s.length; i++)
              v.setUint8(o + i, s.charCodeAt(i));
          v.setUint32(4, 4036, true);
          v.setUint32(16, 16, true);
          v.setUint16(20, 1, true);
          v.setUint16(22, 1, true);
          v.setUint32(24, 8000, true);
          v.setUint32(28, 16000, true);
          v.setUint16(32, 2, true);
          v.setUint16(34, 16, true);
          v.setUint32(40, 4000, true);
          return { data: bytes, mimeType: "audio/wav" };
        },
      };
    },
    { initial, overrides },
  );
  await page.goto("/");
  await expect(
    page.getByRole("heading", { name: "创作台", exact: true }),
  ).toBeVisible();
}
test("navigation, autosave and all seven modes preserve script", async ({
  page,
}) => {
  await launch(page);
  await page.getByLabel("作品名称", { exact: true }).fill("我的作品");
  await page
    .getByLabel("音频脚本", { exact: true })
    .fill("原创内容，不应因切换模式丢失");
  for (const mode of [
    "播客",
    "广告",
    "有声书",
    "广播剧",
    "游戏配音",
    "旁白",
    "自定义",
  ])
    await page.getByRole("button", { name: mode, exact: true }).click();
  await expect(page.getByLabel("音频脚本", { exact: true })).toHaveValue(
    "原创内容，不应因切换模式丢失",
  );
  await expect(page.getByText("已保存到本地", { exact: true })).toBeVisible();
  for (const name of ["作品库", "灵感模板", "设置", "AI 编剧"]) {
    await page
      .getByRole("navigation")
      .getByRole("button", { name, exact: true })
      .click();
    await expect(
      page.getByRole("heading", { name, exact: true }),
    ).toBeVisible();
  }
});
test("preflight exposes exact prompt and cost, cancel makes no submission", async ({
  page,
}) => {
  await launch(page);
  await page.getByLabel("候选数量").selectOption("3");
  await page.getByRole("button", { name: "生成音频", exact: true }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toContainText("3 次付费调用");
  await expect(dialog).toContainText("C:\\Music\\Qwen");
  await expect(dialog).toContainText("今晚，不必急着给生活一个答案");
  await dialog.getByRole("button", { name: "取消", exact: true }).click();
  expect(
    await page.evaluate(
      () => window.calls.filter((c) => c[0] === "submit").length,
    ),
  ).toBe(0);
});
test("confirmed generation submits once and state notification updates history", async ({
  page,
}) => {
  await launch(page);
  await page.getByRole("button", { name: "生成音频", exact: true }).click();
  await page
    .getByRole("button", { name: "确认并开始生成", exact: true })
    .click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  expect(
    await page.evaluate(
      () => window.calls.filter((c) => c[0] === "submit").length,
    ),
  ).toBe(1);
  await page
    .getByRole("navigation")
    .getByRole("button", { name: "作品库", exact: true })
    .click();
  await expect(page.getByText("生成中", { exact: true })).toBeVisible();
  await page.evaluate(() =>
    window.mockState({
      tasks: [
        {
          id: "task-1",
          name: "雨夜里的慢生活",
          status: "completed",
          prompt: "hello",
          params: { format: "wav" },
          seed: 42,
          createdAt: new Date().toISOString(),
          duration: 3,
        },
      ],
    }),
  );
  await expect(
    page.getByRole("button", { name: "播放 雨夜里的慢生活" }),
  ).toBeVisible();
  await expect(page.locator("audio")).toHaveCount(1);
});
test("template variables preview and explicit overwrite apply to draft", async ({
  page,
}) => {
  await launch(page);
  await page
    .getByRole("navigation")
    .getByRole("button", { name: "灵感模板", exact: true })
    .click();
  await page
    .getByRole("button", { name: "使用 雨夜陪伴", exact: true })
    .click();
  await page.getByLabel("节目名称").fill("测试电台");
  await expect(page.getByTestId("template-preview")).toContainText("测试电台");
  await page.getByRole("button", { name: "应用到创作台", exact: true }).click();
  await expect(page.getByRole("dialog")).toContainText("替换当前草稿");
  await page.getByRole("button", { name: "确认替换", exact: true }).click();
  await expect(page.getByLabel("音频脚本", { exact: true })).toContainText("");
  await expect(page.getByLabel("音频脚本", { exact: true })).toHaveValue(
    /测试电台/,
  );
});
test("chat renders model text safely and imports script", async ({ page }) => {
  await launch(page);
  await page
    .getByRole("navigation")
    .getByRole("button", { name: "AI 编剧", exact: true })
    .click();
  await page.getByLabel("创作需求").fill("帮我写旁白");
  await page.getByRole("button", { name: "发送", exact: true }).click();
  await expect(
    page.getByText("<img src=x onerror=alert(1)>", { exact: false }),
  ).toBeVisible();
  await expect(page.locator('img[src="x"]')).toHaveCount(0);
  await page.getByRole("button", { name: "导入创作台", exact: true }).click();
  await page.getByRole("button", { name: "确认替换", exact: true }).click();
  await expect(page.getByLabel("作品名称", { exact: true })).toHaveValue(
    "清晨",
  );
  await expect(page.getByLabel("音频脚本", { exact: true })).toHaveValue(
    "【对白：旁白】清晨的风。",
  );
});
test("settings keep stored credentials write-only and save explicit edits", async ({
  page,
}) => {
  await launch(page);
  await page
    .getByRole("navigation")
    .getByRole("button", { name: "设置", exact: true })
    .click();
  await expect(page.getByLabel("音频 API Key", { exact: true })).toHaveValue(
    "",
  );
  await expect(
    page.getByLabel("音频 API Key", { exact: true }),
  ).toHaveAttribute("type", "password");
  await page.getByLabel("Workspace ID", { exact: true }).fill("new-space");
  await page.getByRole("button", { name: "保存设置", exact: true }).click();
  await expect
    .poll(() =>
      page.evaluate(
        () => window.calls.find((c) => c[0] === "saveSettings")?.[1],
      ),
    )
    .toEqual({
      workspaceID: "new-space",
      chatBaseURL: "https://api.example.com/v1",
      chatModel: "writer",
    });
});
test("library search, favorite, trash and restore are reversible", async ({
  page,
}) => {
  await launch(page, {
    tasks: [
      {
        id: "t1",
        name: "森林旁白",
        status: "completed",
        prompt: "风吹过",
        params: { format: "wav" },
        seed: 5,
        createdAt: "2026-09-30T01:00:00Z",
        duration: 4,
      },
    ],
  });
  await page
    .getByRole("navigation")
    .getByRole("button", { name: "作品库", exact: true })
    .click();
  await page.getByLabel("搜索作品").fill("不存在");
  await expect(page.getByText("暂无匹配作品")).toBeVisible();
  await page.getByLabel("搜索作品").fill("森林");
  await page
    .getByRole("button", { name: "收藏 森林旁白", exact: true })
    .click();
  await page
    .getByRole("button", { name: "移到回收站 森林旁白", exact: true })
    .click();
  await page.getByRole("button", { name: "回收站", exact: true }).click();
  await page
    .getByRole("button", { name: "恢复 森林旁白", exact: true })
    .click();
  await page.getByRole("button", { name: "全部作品", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "播放 森林旁白" }),
  ).toBeVisible();
});
test("reference binding retains stable slots after removal", async ({
  page,
}) => {
  await launch(page, {
    references: [
      { id: "r1", name: "甲", duration: 4 },
      { id: "r2", name: "乙", duration: 5 },
    ],
    draft: {
      ...initial.draft,
      bindings: [
        { referenceID: "r1", alias: "甲", slot: 1 },
        { referenceID: "r2", alias: "乙", slot: 3 },
      ],
    },
  });
  await page
    .getByRole("button", { name: "移除绑定 @voice1", exact: true })
    .click();
  await expect(page.getByText("@voice3", { exact: true })).toBeVisible();
  await expect(page.getByText("@voice2", { exact: true })).toHaveCount(0);
});
test("minimum window has no horizontal overflow and keyboard-visible focus", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1104, height: 681 });
  await launch(page);
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.keyboard.press("Tab");
  await expect(page.locator(":focus")).toBeVisible();
  await page.screenshot({ path: "test-results/creation-1120.png" });
});

test("empty-save shortcut does not prevent later draft autosave", async ({
  page,
}) => {
  await launch(page);
  await page.getByRole("button", { name: "保存草稿", exact: true }).click();
  await page.getByLabel("作品名称", { exact: true }).fill("后续修改");
  await expect
    .poll(() =>
      page.evaluate(
        () => window.calls.filter((c) => c[0] === "saveDraft").at(-1)?.[1].name,
      ),
    )
    .toBe("后续修改");
});
test("advanced parameters persist and choose folder updates the footer", async ({
  page,
}) => {
  await launch(page);
  await page.getByLabel("输出格式").selectOption("mp3");
  await page.getByText("高级输出设置", { exact: true }).click();
  await page.getByLabel("随机种子 Seed", { exact: true }).fill("123");
  await page.getByLabel("固定比特率（仅 MP3）", { exact: true }).check();
  await page.getByLabel("比特率", { exact: true }).selectOption("192");
  await page.getByRole("button", { name: "选择输出目录", exact: true }).click();
  await expect(page.getByText("C:\\Exports", { exact: true })).toBeVisible();
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          window.calls.filter((c) => c[0] === "saveDraft").at(-1)?.[1].params
            .seed,
      ),
    )
    .toBe(123);
});
test("reference crop requires explicit <=30-second selection before save", async ({
  page,
}) => {
  await launch(page);
  await page.evaluate(() => {
    window.studio.pickReference = async () => {
      const samples = new Float32Array(8000 * 40);
      return {
        name: "sample.wav",
        data: AudioTools.encodeSelection(
          {
            sampleRate: 8000,
            length: 8000 * 40,
            duration: 40,
            numberOfChannels: 1,
            getChannelData: () => samples,
          },
          0,
          20,
        ),
      };
    };
  });
  await page
    .getByRole("button", { name: "＋ 添加参考音色", exact: true })
    .click();
  await page.getByRole("button", { name: "导入音频文件", exact: true }).click();
  await expect(page.getByRole("dialog")).toContainText("选择参考音频片段");
  await page.getByLabel("片段开始秒数").fill("2");
  await page.getByLabel("片段结束秒数").fill("1");
  await expect(
    page.getByRole("button", { name: "保存参考音色", exact: true }),
  ).toBeDisabled();
  await page.getByLabel("片段结束秒数").fill("4");
  await page.getByRole("button", { name: "保存参考音色", exact: true }).click();
  await expect(page.getByRole("dialog")).toContainText("sample");
  await expect
    .poll(() =>
      page.evaluate(
        () => window.calls.filter((c) => c[0] === "saveReference").length,
      ),
    )
    .toBe(1);
});
test("completed MP3 explicitly shows unverified duration and structural validation", async ({
  page,
}) => {
  await launch(page, {
    tasks: [
      {
        id: "mp3",
        name: "短片旁白",
        status: "success",
        prompt: "你好",
        params: { format: "mp3" },
        seed: 1,
        createdAt: "2026-09-30T00:00:00Z",
        durationVerified: false,
        validation: "已校验 MPEG 帧结构；未进行解码或时长验证",
      },
    ],
  });
  await page
    .getByRole("navigation")
    .getByRole("button", { name: "作品库", exact: true })
    .click();
  await expect(page.getByText("时长未验证", { exact: true })).toBeVisible();
  await expect(
    page.getByText("已校验 MPEG 帧结构；未进行解码或时长验证", { exact: true }),
  ).toBeVisible();
});
test("recovered downloaded receipt can retry download without resubmitting", async ({
  page,
}) => {
  await launch(page, {
    tasks: [
      {
        id: "recover",
        name: "中断任务",
        status: "interrupted",
        prompt: "你好",
        params: { format: "wav" },
        seed: 1,
        createdAt: "2026-09-30T00:00:00Z",
        canRetryDownload: true,
      },
    ],
  });
  await page
    .getByRole("navigation")
    .getByRole("button", { name: "作品库", exact: true })
    .click();
  await page
    .getByRole("button", { name: "重试下载 中断任务", exact: true })
    .click();
  await expect
    .poll(() =>
      page.evaluate(
        () => window.calls.filter((c) => c[0] === "retryDownload").length,
      ),
    )
    .toBe(1);
  expect(
    await page.evaluate(() => window.calls.some((c) => c[0] === "submit")),
  ).toBe(false);
});
test("native close request flushes a pending draft before acknowledgment", async ({
  page,
}) => {
  await page.addInitScript(() => {
    window.beforeCloseCallback = null;
  });
  await launch(page);
  await page.getByLabel("音频脚本", { exact: true }).fill("关闭前的最后一行");
  await page.evaluate(async () => {
    if (typeof window.beforeCloseCallback !== "function")
      throw new Error("close hook missing");
    await window.beforeCloseCallback();
  });
  expect(
    await page.evaluate(
      () => window.calls.filter((c) => c[0] === "saveDraft").at(-1)[1].prompt,
    ),
  ).toBe("关闭前的最后一行");
});
test("library reuse restores original draft rather than compiled provider prompt", async ({
  page,
}) => {
  await launch(page, {
    tasks: [
      {
        id: "reuse",
        name: "作品",
        status: "success",
        prompt: "已经编译的前缀\n内容与台词：\n剧本",
        params: initial.draft.params,
        seed: 1,
        createdAt: "2026-09-30T00:00:00Z",
        draft: {
          name: "原稿名称",
          mode: "narration",
          prompt: "原始剧本",
          params: initial.draft.params,
          bindings: [],
        },
      },
    ],
  });
  await page
    .getByRole("navigation")
    .getByRole("button", { name: "作品库", exact: true })
    .click();
  await page.getByRole("button", { name: "复用 作品", exact: true }).click();
  await page.getByRole("button", { name: "确认替换", exact: true }).click();
  await expect(page.getByLabel("音频脚本", { exact: true })).toHaveValue(
    "原始剧本",
  );
  await expect(
    page.getByRole("button", { name: "旁白", exact: true }),
  ).toHaveAttribute("aria-pressed", "true");
});
test("script count uses Unicode code points", async ({ page }) => {
  await launch(page);
  await page.getByLabel("音频脚本", { exact: true }).fill("你好😀");
  await expect(page.locator("#character-count")).toHaveText(
    "3 字符 · 完整请求上限 3000",
  );
});
test("active tasks cannot be renamed, favorited or trashed", async ({
  page,
}) => {
  await launch(page, {
    tasks: [
      {
        id: "active",
        name: "进行中作品",
        status: "requesting",
        prompt: "台词",
        params: initial.draft.params,
        seed: 1,
        createdAt: "2026-09-30T00:00:00Z",
      },
    ],
  });
  await page
    .getByRole("navigation")
    .getByRole("button", { name: "作品库", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "重命名 进行中作品", exact: true }),
  ).toBeDisabled();
  await expect(
    page.getByRole("button", { name: "收藏 进行中作品", exact: true }),
  ).toBeDisabled();
  await expect(
    page.getByRole("button", { name: "移到回收站 进行中作品", exact: true }),
  ).toBeDisabled();
});

test("generation controls stay in viewport at the minimum Windows client area", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1104, height: 681 });
  await launch(page);
  await expect(
    page.getByRole("button", { name: "生成音频", exact: true }),
  ).toBeInViewport();
  expect(
    await page
      .locator("#content")
      .evaluate((node) => node.scrollHeight <= node.clientHeight + 1),
  ).toBe(true);
});
