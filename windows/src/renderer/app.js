/* Local, sandboxed renderer. All filesystem/network/credential work is behind studio. */
(function () {
  "use strict";
  const api = window.studio;
  const $ = (id) => document.getElementById(id);
  const modes = {
    podcast: "播客",
    advertisement: "广告",
    audiobook: "有声书",
    drama: "广播剧",
    game: "游戏配音",
    narration: "旁白",
    auto: "自定义",
  };
  const defaults = {
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
  };
  const pages = {
    chat: ["AI 编剧", "LET A GOOD STORY FIND ITS VOICE", "spark"],
    create: ["创作台", "CREATE SOMETHING WORTH HEARING", "edit"],
    library: ["作品库", "EVERY SOUND TELLS A STORY", "library"],
    templates: ["灵感模板", "A LITTLE INSPIRATION GOES A LONG WAY", "grid"],
    settings: ["设置", "MAKE YOURSELF AT HOME", "settings"],
  };
  const statusNames = {
    preparing: "准备中",
    requesting: "生成中",
    generating: "生成中",
    downloading: "下载中",
    validating: "校验中",
    success: "已完成",
    completed: "已完成",
    uncertain: "结果待核实",
    download_failed: "下载失败",
    failed: "生成失败",
    interrupted: "已中断",
  };
  let state,
    draft,
    page = "create",
    saveVersion = 0,
    savedVersion = 0,
    saveTimer,
    savePromise,
    toastTimer,
    candidates = 1;
  let libraryFilter = "all",
    librarySearch = "",
    templateMode = "all",
    templateSearch = "",
    templateFavoriteOnly = false,
    compare = [];
  let currentAudioURL,
    currentAudioID,
    audioVersion = 0,
    chatBusy = false,
    chatInput = "",
    modalCleanup,
    preflightBusy = false,
    modalLocked = false;
  const clone = (value) => structuredClone(value);
  const characterCount = (text) =>
    Array.from(text).length + " 字符 · 完整请求上限 3000";
  function el(tag, attrs = {}, ...children) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs)) {
      if (value === undefined || value === null) continue;
      if (key === "class") node.className = value;
      else if (key === "text") node.textContent = value;
      else if (key.startsWith("on"))
        node.addEventListener(key.slice(2), (event) => {
          try {
            Promise.resolve(value(event)).catch(showError);
          } catch (error) {
            showError(error);
          }
        });
      else if (key in node && !key.startsWith("aria-") && key !== "form")
        node[key] = value;
      else node.setAttribute(key, String(value));
    }
    for (const child of children.flat(Infinity))
      if (child !== undefined && child !== null)
        node.append(
          child instanceof Node
            ? child
            : document.createTextNode(String(child)),
        );
    return node;
  }
  function icon(name) {
    const paths = {
      spark:
        "M12 3 14.5 9.5 21 12 14.5 14.5 12 21 9.5 14.5 3 12 9.5 9.5ZM20 3v4M18 5h4",
      edit: "m15 4 5 5M4 20l5-1L20 8a2 2 0 0 0-5-5L4 14Z",
      library: "M4 4h4v16H4zM10 4h4v16h-4zM17 5l3-1 4 15-3 1z",
      grid: "M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z",
      settings:
        "M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8ZM12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M5 19l2-2M17 7l2-2",
      wave: "M3 10v4M7 6v12M12 2v20M17 6v12M21 10v4",
    };
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("fill", "none");
    svg.setAttribute("stroke", "currentColor");
    svg.setAttribute("stroke-width", "1.6");
    svg.setAttribute("stroke-linecap", "round");
    svg.setAttribute("stroke-linejoin", "round");
    svg.setAttribute("aria-hidden", "true");
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("d", paths[name] || paths.wave);
    svg.append(path);
    return svg;
  }
  const button = (text, fn, cls = "", attrs = {}) =>
    el("button", { type: "button", class: cls, onclick: fn, ...attrs }, text);
  const field = (label, input, help) =>
    el(
      "label",
      { class: "field" },
      el("span", {}, label),
      input,
      help ? el("small", {}, help) : null,
    );
  function select(label, values, value, onchange, attrs = {}) {
    return el(
      "select",
      {
        "aria-label": label,
        onchange: (event) => onchange(event.target.value),
        ...attrs,
      },
      values.map((item) => {
        const [v, t] = Array.isArray(item) ? item : [item, item];
        return el(
          "option",
          { value: v, selected: String(v) === String(value) },
          t,
        );
      }),
    );
  }
  function toast(message, error = false) {
    clearTimeout(toastTimer);
    $("toast").textContent = message;
    $("toast").className = error ? "error" : "";
    $("toast").hidden = false;
    toastTimer = setTimeout(
      () => {
        $("toast").hidden = true;
      },
      error ? 8500 : 3500,
    );
  }
  function showError(error) {
    toast(error?.message || String(error) || "操作未完成，请重试", true);
  }
  function setSaveStatus(text) {
    document.querySelectorAll("[data-save-status]").forEach((node) => {
      node.textContent = text;
    });
  }
  function changed() {
    saveVersion++;
    setSaveStatus("有未保存更改");
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => saveNow().catch(showError), 550);
  }
  async function saveNow() {
    clearTimeout(saveTimer);
    if (savePromise) return savePromise;
    if (savedVersion === saveVersion) return;
    savePromise = (async () => {
      try {
        while (savedVersion !== saveVersion) {
          const version = saveVersion;
          const snapshot = clone(draft);
          setSaveStatus("正在保存…");
          await api.saveDraft(snapshot);
          savedVersion = version;
        }
        setSaveStatus("已保存到本地");
      } catch (error) {
        setSaveStatus("保存失败 · 请重试");
        throw error;
      } finally {
        savePromise = null;
      }
    })();
    return savePromise;
  }
  function updateState(next) {
    if (!next?.draft) return;
    state = next;
    // Async state events must never replace an unsaved or focused draft.
    if (page === "library") renderLibrary();
    if (page === "templates") renderTemplates();
    if (page === "chat") renderMessages();
    if (page === "create") {
      renderBindings();
      updateFolder();
    }
    if ($("generation-progress"))
      $("generation-progress").textContent =
        (state.tasks || [])
          .slice(0, 3)
          .map((t) => t.name + " · " + (statusNames[t.status] || t.status))
          .join(" / ") || "正在准备生成任务…";
    $("version").textContent =
      "WINDOWS EDITION / " + (state.version || "0.1.0");
  }
  function renderNavigation() {
    $("navigation").replaceChildren(
      ...Object.entries(pages).map(([key, [name, , glyph]]) =>
        button(
          [icon(glyph), el("span", {}, name)],
          () => navigate(key),
          key === page ? "active" : "",
          { "aria-current": key === page ? "page" : null },
        ),
      ),
    );
  }
  function navigate(next) {
    page = next;
    $("content").dataset.page = page;
    renderNavigation();
    $("page-title").textContent = pages[page][0];
    $("page-eyebrow").textContent = pages[page][1];
    $("page-actions").replaceChildren();
    renderCurrent();
  }
  function renderCurrent() {
    ({
      create: renderCreate,
      library: renderLibrary,
      templates: renderTemplates,
      settings: renderSettings,
      chat: renderChat,
    })[page]();
  }
  function openModal(title, body, actions = [], cleanup) {
    if ($("modal").open) closeModal();
    modalCleanup = cleanup;
    $("modal").replaceChildren(
      el(
        "div",
        { class: "modal-header" },
        el("h2", { id: "modal-title" }, title),
        button("×", closeModal, "quiet", { "aria-label": "关闭对话框" }),
      ),
      el("div", { class: "modal-body" }, body),
      el("div", { class: "modal-footer" }, actions),
    );
    $("modal").showModal();
  }
  function closeModal() {
    if (modalLocked || !$("modal").open) return;
    $("modal").close();
    const cleanup = modalCleanup;
    modalCleanup = null;
    if (cleanup) Promise.resolve(cleanup()).catch(showError);
  }
  $("modal").addEventListener("cancel", (event) => {
    event.preventDefault();
    closeModal();
  });
  async function replaceDraft(next) {
    const apply = async () => {
      draft = {
        ...draft,
        ...next,
        params: { ...defaults, ...draft.params, ...next.params },
        bindings: next.bindings ?? draft.bindings,
      };
      changed();
      await saveNow();
      closeModal();
      navigate("create");
      toast("已导入创作台");
    };
    if (draft.prompt.trim()) {
      openModal(
        "替换当前草稿？",
        el(
          "div",
          { class: "stack" },
          el(
            "p",
            {},
            "导入内容会替换当前作品名称、模式与脚本。请确认当前内容已不再需要。",
          ),
          el(
            "p",
            { class: "notice" },
            "参考音色和输出参数会保留，除非你正在复用作品。",
          ),
        ),
        [button("取消", closeModal), button("确认替换", apply, "primary")],
      );
    } else await apply();
  }
  function inputParam(key, label, type = "number", attrs = {}) {
    return el("input", {
      type,
      value: draft.params[key],
      "aria-label": label,
      ...attrs,
      oninput: (event) => {
        draft.params[key] =
          type === "number" || type === "range"
            ? Number(event.target.value)
            : event.target.value;
        changed();
      },
    });
  }
  function rangeParam(key, label, min, max, step, suffix = "") {
    const output = el("output", {}, draft.params[key] + suffix);
    const input = inputParam(key, label, "range", { min, max, step });
    input.addEventListener("input", () => {
      output.textContent = draft.params[key] + suffix;
    });
    return field(label, el("div", { class: "range-line" }, input, output));
  }
  function renderCreate() {
    $("page-actions").replaceChildren(
      button("保存草稿", () => saveNow(), "quiet"),
      button("新建草稿", () =>
        replaceDraft({
          name: "未命名作品",
          mode: "podcast",
          prompt: "",
          bindings: [],
        }),
      ),
    );
    const title = el("input", {
      class: "draft-title",
      "aria-label": "作品名称",
      value: draft.name,
      maxLength: 120,
      oninput: (event) => {
        draft.name = event.target.value;
        changed();
      },
    });
    const modeStrip = el(
      "div",
      { class: "mode-strip", "aria-label": "创作模式" },
      Object.entries(modes).map(([key, name]) =>
        button(
          name,
          () => {
            draft.mode = key;
            changed();
            for (const node of modeStrip.children) {
              node.classList.toggle("active", node.dataset.mode === key);
              node.setAttribute(
                "aria-pressed",
                String(node.dataset.mode === key),
              );
            }
          },
          key === draft.mode ? "active" : "",
          { "data-mode": key, "aria-pressed": String(key === draft.mode) },
        ),
      ),
    );
    const prompt = el("textarea", {
      class: "script-editor",
      id: "script-editor",
      "aria-label": "音频脚本",
      value: draft.prompt,
      spellcheck: false,
      placeholder: "描述场景、角色、对白，以及你想让人听见的一切…",
      oninput: (event) => {
        draft.prompt = event.target.value;
        changed();
        $("character-count").textContent = characterCount(draft.prompt);
      },
    });
    const advanced = el(
      "details",
      {},
      el("summary", {}, "高级输出设置"),
      el(
        "div",
        { class: "stack" },
        field(
          "声道",
          select(
            "声道",
            [
              [1, "单声道"],
              [2, "立体声"],
            ],
            draft.params.channels,
            (value) => {
              draft.params.channels = Number(value);
              changed();
            },
          ),
        ),
        field(
          "随机种子 Seed",
          inputParam("seed", "随机种子 Seed", "number", {
            min: 0,
            max: Number.MAX_SAFE_INTEGER,
            step: 1,
          }),
          "多个候选将使用不同的 Seed",
        ),
        checkboxParam("enableCBR", "固定比特率（仅 MP3）"),
        field(
          "比特率",
          select(
            "比特率",
            [64, 128, 192, 256, 320].map((v) => [v, v + " kbps"]),
            draft.params.bitRate,
            (value) => {
              draft.params.bitRate = Number(value);
              changed();
            },
          ),
        ),
        field(
          "MP3 音质（0–9）",
          inputParam("quality", "MP3 音质", "number", {
            min: 0,
            max: 9,
            step: 1,
          }),
        ),
        checkboxParam("enableAIGCTag", "添加 AI 生成标识"),
      ),
    );
    $("content").replaceChildren(
      el(
        "div",
        { class: "editor-top" },
        title,
        el(
          "span",
          { class: "save-status", "data-save-status": "" },
          saveVersion === savedVersion ? "已保存到本地" : "有未保存更改",
        ),
        modeStrip,
      ),
      el(
        "section",
        { class: "editor-layout" },
        el(
          "div",
          { class: "script-pane" },
          el(
            "div",
            { class: "script-toolbar" },
            el(
              "div",
              {},
              el("h2", {}, "让故事有声有色"),
              el("p", { class: "section-kicker" }, "SCRIPT / 脚本编辑器"),
            ),
            button("保存为模板", saveAsTemplate, "quiet small"),
          ),
          el(
            "div",
            { class: "tag-strip" },
            ["场景", "角色：讲述者", "对白：讲述者", "音效", "音乐"].map(
              (tag) =>
                button("＋ " + tag, () => {
                  const pos = prompt.selectionStart;
                  const token = "【" + tag + "】";
                  prompt.setRangeText(token, pos, prompt.selectionEnd, "end");
                  draft.prompt = prompt.value;
                  changed();
                  prompt.focus();
                  $("character-count").textContent = characterCount(
                    draft.prompt,
                  );
                }),
            ),
          ),
          prompt,
          el(
            "div",
            { class: "script-bottom" },
            el("span", {}, "用文字编排声音，用细节营造现场"),
            el("span", { id: "character-count" }, characterCount(draft.prompt)),
          ),
        ),
        el(
          "aside",
          { class: "inspector" },
          el("h2", {}, "声音与输出"),
          el(
            "p",
            { class: "section-note" },
            "在「角色」标签里，描述声音的情绪、质感和语气。",
          ),
          button("＋ 添加参考音色", openReferences),
          el("div", { id: "bindings", class: "binding-list" }),
          el("div", { class: "divider" }),
          el("h3", {}, "输出设置"),
          el(
            "div",
            { class: "two-fields" },
            field(
              "格式",
              select(
                "输出格式",
                ["wav", "mp3", "pcm"].map((x) => [x, x.toUpperCase()]),
                draft.params.format,
                (value) => {
                  draft.params.format = value;
                  changed();
                },
              ),
            ),
            field(
              "采样率",
              select(
                "采样率",
                [
                  [8000, "8 kHz"],
                  [16000, "16 kHz"],
                  [24000, "24 kHz"],
                  [44100, "44.1 kHz"],
                  [48000, "48 kHz"],
                ],
                draft.params.sampleRate,
                (value) => {
                  draft.params.sampleRate = Number(value);
                  changed();
                },
              ),
            ),
          ),
          rangeParam("rate", "语速", 0.5, 2, 0.1, "×"),
          rangeParam("volume", "音量", 0, 100, 1),
          advanced,
        ),
        el(
          "div",
          { class: "editor-footer" },
          el(
            "div",
            { class: "stack" },
            el(
              "div",
              { class: "row" },
              button("选择输出目录", chooseFolder, "small"),
              el("span", { id: "output-folder", class: "folder" }),
            ),
            el(
              "span",
              { class: "footer-label" },
              "生成前可核对完整脚本与参考音色",
            ),
          ),
          el(
            "div",
            { class: "row" },
            select(
              "候选数量",
              [
                [1, "1 个候选"],
                [2, "2 个候选"],
                [3, "3 个候选"],
              ],
              candidates,
              (value) => {
                candidates = Number(value);
              },
              { class: "candidate-select" },
            ),
            button("生成音频", preflight, "primary generation-button", {
              id: "generate-button",
            }),
          ),
        ),
      ),
      el(
        "div",
        { class: "below-editor" },
        el("span", {}, "Qwen Audio Next · 对白 / 音效 / 音乐，一次创作"),
        el("span", {}, "本地自动保存 · Ctrl + S"),
      ),
    );
    renderBindings();
    updateFolder();
  }
  function checkboxParam(key, label) {
    return el(
      "label",
      { class: "checkbox-label" },
      el("input", {
        type: "checkbox",
        checked: draft.params[key],
        onchange: (event) => {
          draft.params[key] = event.target.checked;
          changed();
        },
      }),
      label,
    );
  }
  function renderBindings() {
    const box = $("bindings");
    if (!box) return;
    box.replaceChildren(
      ...(draft.bindings || []).map((binding) =>
        el(
          "div",
          { class: "binding" },
          el("span", {}, "@voice" + binding.slot),
          el(
            "span",
            { class: "binding-name" },
            binding.alias ||
              state.references.find((r) => r.id === binding.referenceID)
                ?.name ||
              "参考音色",
          ),
          button(
            "×",
            () => {
              draft.bindings = draft.bindings.filter(
                (b) => b.slot !== binding.slot,
              );
              changed();
              renderBindings();
            },
            "quiet",
            { "aria-label": "移除绑定 @voice" + binding.slot },
          ),
        ),
      ),
    );
  }
  function updateFolder() {
    if ($("output-folder")) {
      $("output-folder").textContent =
        state.settings.outputDirectory || "尚未选择输出目录";
      $("output-folder").title = state.settings.outputDirectory || "";
    }
  }
  async function chooseFolder() {
    const path = await api.chooseOutputDirectory();
    if (path) {
      state.settings.outputDirectory = path;
      updateFolder();
      toast("输出目录已更新");
    }
  }
  async function preflight() {
    if (preflightBusy) return;
    preflightBusy = true;
    const trigger = $("generate-button");
    trigger.disabled = true;
    try {
      await saveNow();
      const plan = await api.preflight({ draft: clone(draft), candidates });
      let submitted = false,
        submitting = false;
      const info = el(
        "div",
        {},
        el(
          "p",
          { class: "warning" },
          plan.calls +
            " 次付费调用 · 每个候选单独计费。实际费用以服务商账单为准，无法在此预先确定金额。",
        ),
        el(
          "dl",
          { class: "review-grid" },
          el(
            "div",
            {},
            el("dt", {}, "输出目录"),
            el("dd", {}, plan.outputDirectory),
          ),
          el(
            "div",
            {},
            el("dt", {}, "候选 Seed"),
            el("dd", {}, (plan.seeds || []).join(" / ")),
          ),
          el(
            "div",
            {},
            el("dt", {}, "音频格式"),
            el(
              "dd",
              {},
              String(plan.params.format).toUpperCase() +
                " · " +
                plan.params.sampleRate +
                " Hz · " +
                plan.params.channels +
                " 声道",
            ),
          ),
          el(
            "div",
            {},
            el("dt", {}, "参考文件"),
            el(
              "dd",
              {},
              plan.references.length
                ? plan.references
                    .map(
                      (r) =>
                        "@voice" +
                        r.slot +
                        " · " +
                        r.name +
                        " (" +
                        Number(r.duration).toFixed(1) +
                        "s)",
                    )
                    .join("\n")
                : "无参考音频",
            ),
          ),
        ),
        el(
          "p",
          { class: "notice" },
          "以下是将发送到音频服务的完整脚本；所列参考音频也将上传。",
        ),
        el("pre", { class: "prompt-preview" }, plan.prompt),
        el(
          "p",
          { class: "notice" },
          "确认后只发送一次。网络中断或结果不明时不会自动重新付费生成。",
        ),
      );
      const confirm = button(
        "确认并开始生成",
        async () => {
          if (submitting) return;
          submitting = true;
          modalLocked = true;
          confirm.disabled = true;
          cancel.disabled = true;
          confirm.textContent = "正在生成…";
          info.append(
            el(
              "p",
              { id: "generation-progress", class: "notice", role: "status" },
              "正在准备生成任务…",
            ),
          );
          try {
            await api.submit(plan.token);
            submitted = true;
            modalLocked = false;
            closeModal();
            toast("生成请求已处理，请查看作品状态");
            navigate("library");
          } catch (error) {
            submitted = true;
            modalLocked = false;
            closeModal();
            navigate("library");
            throw error;
          }
        },
        "primary",
      );
      const cancel = button("取消", closeModal);
      openModal("生成前，请确认", info, [cancel, confirm], async () => {
        if (!submitted && !submitting && api.cancelPreflight)
          await api.cancelPreflight(plan.token);
      });
    } finally {
      preflightBusy = false;
      if (trigger.isConnected) trigger.disabled = false;
    }
  }
  function allTemplates() {
    return [
      ...(state.templates || []),
      ...(state.customTemplates || []),
    ].filter((t, i, a) => a.findIndex((x) => x.id === t.id) === i);
  }
  function renderTemplates() {
    const list = allTemplates().filter(
      (t) =>
        (templateMode === "all" || t.mode === templateMode) &&
        (!templateFavoriteOnly ||
          (state.templateFavorites || []).includes(t.id)) &&
        [t.name, t.description, ...(t.tags || [])]
          .join(" ")
          .toLowerCase()
          .includes(templateSearch.toLowerCase()),
    );
    $("page-actions").replaceChildren(
      el("span", { class: "muted" }, allTemplates().length + " 个灵感起点"),
    );
    const search = el("input", {
      type: "search",
      "aria-label": "搜索模板",
      placeholder: "搜索名称、场景或关键词",
      value: templateSearch,
      oninput: (event) => {
        templateSearch = event.target.value;
        renderTemplateCards();
      },
    });
    $("content").replaceChildren(
      el(
        "div",
        { class: "toolbar" },
        search,
        select(
          "模板模式",
          [["all", "全部类型"], ...Object.entries(modes)],
          templateMode,
          (value) => {
            templateMode = value;
            renderTemplates();
          },
        ),
        button(
          templateFavoriteOnly ? "★ 已收藏" : "☆ 我的收藏",
          () => {
            templateFavoriteOnly = !templateFavoriteOnly;
            renderTemplates();
          },
          templateFavoriteOnly ? "active" : "",
        ),
      ),
      el("div", { class: "template-grid", id: "template-grid" }),
    );
    renderTemplateCards(list);
  }
  function renderTemplateCards(given) {
    const list =
      given ||
      allTemplates().filter(
        (t) =>
          (templateMode === "all" || t.mode === templateMode) &&
          (!templateFavoriteOnly ||
            (state.templateFavorites || []).includes(t.id)) &&
          [t.name, t.description, ...(t.tags || [])]
            .join(" ")
            .toLowerCase()
            .includes(templateSearch.toLowerCase()),
      );
    const container = $("template-grid");
    if (!container) return;
    container.replaceChildren(
      ...list.map((template) =>
        el(
          "article",
          { class: "template-card" },
          el("div", { class: "template-art" }, icon("wave")),
          el(
            "div",
            { class: "template-body" },
            el(
              "div",
              { class: "template-title" },
              el("h3", {}, template.name),
              button(
                (state.templateFavorites || []).includes(template.id)
                  ? "★"
                  : "☆",
                () =>
                  api.favoriteTemplate({
                    id: template.id,
                    favorite: !(state.templateFavorites || []).includes(
                      template.id,
                    ),
                  }),
                "",
                { "aria-label": "收藏模板 " + template.name },
              ),
            ),
            el("p", {}, template.description || "从你保存的脚本继续创作"),
            el(
              "div",
              { class: "template-meta" },
              el("span", {}, modes[template.mode] || "自定义"),
              el(
                "span",
                {},
                template.role_count ? template.role_count + " 个角色" : "",
              ),
              el(
                "span",
                {},
                template.suggested_duration_seconds
                  ? "约 " + template.suggested_duration_seconds + " 秒"
                  : "",
              ),
            ),
            el(
              "div",
              { class: "row" },
              button("使用模板", () => openTemplate(template), "small", {
                "aria-label": "使用 " + template.name,
              }),
              state.customTemplates?.some((t) => t.id === template.id)
                ? button(
                    "移除",
                    () => confirmRemoveTemplate(template),
                    "quiet small",
                  )
                : el("span", { class: "muted" }, "↗"),
            ),
          ),
        ),
      ),
    );
    if (!list.length)
      container.append(el("div", { class: "empty-state" }, "暂无匹配模板"));
  }
  function openTemplate(template) {
    const values = Object.fromEntries(
      (template.variables || []).map((v) => [v.key, v.default ?? ""]),
    );
    const preview = el("pre", {
      class: "prompt-preview",
      "data-testid": "template-preview",
    });
    const update = () => {
      preview.textContent = template.prompt_pattern.replace(
        /\{\{(\w+)\}\}/g,
        (_, key) => values[key] ?? "",
      );
    };
    update();
    const inputs = (template.variables || []).map((variable) =>
      field(
        variable.label,
        el(variable.type === "textarea" ? "textarea" : "input", {
          "aria-label": variable.label,
          value: values[variable.key],
          required: variable.required,
          maxLength: variable.max_length || 1000,
          oninput: (event) => {
            values[variable.key] = event.target.value;
            update();
          },
        }),
      ),
    );
    openModal(
      template.name,
      el(
        "div",
        { class: "stack" },
        el("p", { class: "notice" }, "填入你的细节，预览将实时更新。"),
        inputs,
        el("div", {}, el("h3", {}, "脚本预览"), preview),
      ),
      [
        button("取消", closeModal),
        button(
          "应用到创作台",
          async () => {
            for (const v of template.variables || [])
              if (v.required && !String(values[v.key]).trim())
                throw new Error("请填写「" + v.label + "」");
            const expanded = await api.expandTemplate({
              id: template.id,
              values,
            });
            await replaceDraft({
              ...expanded,
              params: expanded.params || template.params_preset || draft.params,
            });
          },
          "primary",
        ),
      ],
    );
  }
  function saveAsTemplate() {
    if (!draft.prompt.trim()) throw new Error("请先填写脚本");
    const name = el("input", {
      "aria-label": "模板名称",
      value: draft.name,
      maxLength: 80,
    });
    const description = el("input", {
      "aria-label": "模板描述",
      placeholder: "用一句话描述这个灵感",
      maxLength: 240,
    });
    openModal(
      "保存为自定义模板",
      el(
        "div",
        { class: "stack" },
        field("模板名称", name),
        field("模板描述", description),
        el(
          "p",
          { class: "notice" },
          "只保存名称、模式与脚本，不包含参考音色文件或输出参数。",
        ),
      ),
      [
        button("取消", closeModal),
        button(
          "保存模板",
          async () => {
            await api.saveTemplate({
              name: name.value.trim(),
              mode: draft.mode,
              description: description.value,
              prompt_pattern: draft.prompt,
              variables: [],
              tags: [],
              role_count: 0,
              suggested_duration_seconds: 30,
              params_preset: clone(draft.params),
            });
            closeModal();
            toast("已保存到灵感模板");
          },
          "primary",
        ),
      ],
    );
  }
  function confirmRemoveTemplate(template) {
    openModal(
      "移除自定义模板？",
      el(
        "p",
        {},
        "将从模板库移除「" + template.name + "」，当前草稿不会改变。",
      ),
      [
        button("取消", closeModal),
        button(
          "确认移除",
          async () => {
            await api.removeTemplate(template.id);
            closeModal();
          },
          "danger",
        ),
      ],
    );
  }
  function renderLibrary() {
    const active = (state.tasks || []).filter((t) => !t.trashed);
    $("page-actions").replaceChildren(
      el("span", { class: "muted" }, active.length + " 件作品"),
    );
    const search = el("input", {
      type: "search",
      "aria-label": "搜索作品",
      placeholder: "搜索作品名称或脚本",
      value: librarySearch,
      oninput: (event) => {
        librarySearch = event.target.value;
        renderTaskList();
      },
    });
    $("content").replaceChildren(
      el(
        "div",
        { class: "toolbar" },
        el(
          "div",
          { class: "tabs" },
          [
            ["all", "全部作品"],
            ["favorite", "收藏"],
            ["trash", "回收站"],
          ].map(([key, name]) =>
            button(
              name,
              () => {
                libraryFilter = key;
                renderLibrary();
              },
              libraryFilter === key ? "active" : "",
            ),
          ),
        ),
        search,
      ),
      el("div", { id: "compare" }),
      el("div", { id: "task-list" }),
    );
    renderTaskList();
  }
  function finished(task) {
    return ["success", "completed"].includes(task.status);
  }
  function renderTaskList() {
    const box = $("task-list");
    if (!box) return;
    const list = (state.tasks || []).filter(
      (t) =>
        (libraryFilter === "trash" ? !!t.trashed : !t.trashed) &&
        (libraryFilter !== "favorite" || t.favorite) &&
        [t.name, t.prompt]
          .join(" ")
          .toLowerCase()
          .includes(librarySearch.toLowerCase()),
    );
    box.className = list.length ? "task-list" : "";
    box.replaceChildren(
      ...list.map((task) => {
        const actions = [];
        const modifiable = [
          "success",
          "completed",
          "failed",
          "uncertain",
          "interrupted",
          "download_failed",
        ].includes(task.status);
        if (task.trashed)
          actions.push(
            button(
              "恢复",
              () => api.updateTask({ id: task.id, trashed: false }),
              "",
              { "aria-label": "恢复 " + task.name },
            ),
          );
        else {
          actions.push(
            button(
              task.favorite ? "★" : "☆",
              () => api.updateTask({ id: task.id, favorite: !task.favorite }),
              "",
              {
                "aria-label":
                  (task.favorite ? "取消收藏 " : "收藏 ") + task.name,
                disabled: !modifiable,
              },
            ),
          );
          actions.push(
            button(
              "复用",
              () =>
                replaceDraft(
                  task.draft || {
                    name: task.name,
                    mode: task.mode || "auto",
                    prompt: task.prompt,
                    params: { ...defaults, ...task.params },
                    bindings: task.bindings || [],
                  },
                ),
              "",
              { "aria-label": "复用 " + task.name },
            ),
          );
          actions.push(
            button("重命名", () => renameTask(task), "", {
              "aria-label": "重命名 " + task.name,
              disabled: !modifiable,
            }),
          );
          if (finished(task)) {
            actions.push(
              button(
                "导出",
                async () => {
                  const path = await api.exportTask(task.id);
                  if (path) toast("已导出到 " + path);
                },
                "",
                { "aria-label": "导出 " + task.name },
              ),
              button("打开位置", () => api.revealTask(task.id), "", {
                "aria-label": "打开位置 " + task.name,
              }),
              button(
                compare.includes(task.id) ? "已选对比" : "A/B 对比",
                () => {
                  if (compare.includes(task.id))
                    compare = compare.filter((id) => id !== task.id);
                  else if (compare.length < 2) compare.push(task.id);
                  else throw new Error("最多选择两个作品进行 A/B 对比");
                  renderTaskList();
                },
                "",
                { "aria-label": "对比 " + task.name },
              ),
            );
          }
          if (task.status === "download_failed" || task.canRetryDownload)
            actions.push(
              button("重试下载", () => api.retryDownload(task.id), "", {
                "aria-label": "重试下载 " + task.name,
              }),
            );
          actions.push(
            button(
              "回收站",
              () => api.updateTask({ id: task.id, trashed: true }),
              "quiet",
              {
                "aria-label": "移到回收站 " + task.name,
                disabled: !modifiable,
              },
            ),
          );
        }
        const date = new Date(task.createdAt);
        return el(
          "article",
          { class: "task-row" },
          button(
            "▶",
            () => playItem("task", task.id, task.name),
            "play-circle",
            { "aria-label": "播放 " + task.name, disabled: !finished(task) },
          ),
          el(
            "div",
            {},
            el("h3", {}, task.name),
            el(
              "div",
              { class: "task-meta" },
              el(
                "span",
                {
                  class:
                    "status " +
                    ([
                      "requesting",
                      "preparing",
                      "generating",
                      "downloading",
                      "validating",
                    ].includes(task.status)
                      ? "busy"
                      : [
                            "failed",
                            "uncertain",
                            "download_failed",
                            "interrupted",
                          ].includes(task.status)
                        ? "failure"
                        : ""),
                },
                statusNames[task.status] || task.status,
              ),
              el(
                "span",
                {},
                task.durationVerified === false
                  ? "时长未验证"
                  : Number.isFinite(task.duration)
                    ? task.duration.toFixed(1) + " 秒"
                    : String(task.params?.format || "wav").toUpperCase(),
              ),
              el("span", {}, "Seed " + task.seed),
              el(
                "span",
                {},
                Number.isNaN(date.valueOf())
                  ? ""
                  : date.toLocaleString("zh-CN", {
                      month: "2-digit",
                      day: "2-digit",
                      hour: "2-digit",
                      minute: "2-digit",
                    }),
              ),
            ),
            task.validation
              ? el("p", { class: "notice" }, task.validation)
              : null,
            !finished(task) && task.error
              ? el("p", { class: "task-error" }, task.error)
              : null,
            task.status === "uncertain"
              ? el(
                  "p",
                  { class: "task-error" },
                  "服务可能已受理，请先核对服务商账单。为避免重复收费，此任务不会自动重发。",
                )
              : null,
          ),
          el("div", { class: "task-actions" }, actions),
        );
      }),
    );
    if (!list.length)
      box.append(
        el(
          "div",
          { class: "empty-state" },
          el("strong", {}, "暂无匹配作品"),
          libraryFilter === "trash"
            ? "移到回收站的作品可以随时恢复"
            : "在创作台写下第一段故事，让灵感变成声音",
        ),
      );
    compare = compare.filter((id) =>
      state.tasks.some((t) => t.id === id && !t.trashed && finished(t)),
    );
    $("compare").replaceChildren();
    if (compare.length) {
      $("compare").append(
        el(
          "div",
          { class: "compare-bar" },
          el("strong", {}, "A/B 试听"),
          compare.map((id, i) => {
            const task = state.tasks.find((t) => t.id === id);
            return button(
              (i ? "B" : "A") + " · " + task.name,
              () => playItem("task", id, task.name),
              "small",
            );
          }),
          button(
            "清空选择",
            () => {
              compare = [];
              renderTaskList();
            },
            "quiet small",
          ),
        ),
      );
    }
  }
  function renameTask(task) {
    const input = el("input", {
      "aria-label": "新作品名称",
      value: task.name,
      maxLength: 120,
    });
    openModal("重命名作品", field("作品名称", input), [
      button("取消", closeModal),
      button(
        "保存",
        async () => {
          await api.updateTask({ id: task.id, name: input.value.trim() });
          closeModal();
        },
        "primary",
      ),
    ]);
  }
  function stopAudio() {
    audioVersion++;
    $("audio-player").pause();
    $("audio-player").removeAttribute("src");
    $("audio-player").load();
    if (currentAudioURL) URL.revokeObjectURL(currentAudioURL);
    currentAudioURL = null;
    currentAudioID = null;
    $("player-title").textContent = "听见你的下一段灵感";
    $("player-caption").textContent = "选择作品或参考音色，开始试听";
  }
  async function playBytes(data, mime, title, id, requestVersion) {
    if (requestVersion !== undefined && requestVersion !== audioVersion) return;
    const audio = $("audio-player");
    audio.pause();
    if (currentAudioURL) URL.revokeObjectURL(currentAudioURL);
    currentAudioURL = URL.createObjectURL(new Blob([data], { type: mime }));
    currentAudioID = id;
    audio.src = currentAudioURL;
    $("player-title").textContent = title;
    $("player-caption").textContent = "本地音频 · 支持拖动进度试听";
    try {
      await audio.play();
    } catch (error) {
      if (error.name !== "AbortError")
        throw new Error("无法播放此音频。可导出后使用系统播放器试听。");
    }
  }
  async function playItem(kind, id, title) {
    const audio = $("audio-player");
    if (currentAudioID === id && audio.src) {
      if (audio.paused) await audio.play();
      else audio.pause();
      return;
    }
    const requestVersion = ++audioVersion;
    const result = await api.readAudio({ kind, id });
    await playBytes(result.data, result.mimeType, title, id, requestVersion);
  }
  $("player-stop").addEventListener("click", stopAudio);
  $("audio-player").addEventListener("error", () => {
    if ($("audio-player").getAttribute("src"))
      showError(new Error("音频暂时无法播放，请重试或导出文件"));
  });
  function renderSettings() {
    const settings = state.settings || {},
      credentials = state.credentials || {};
    const workspace = el("input", {
      "aria-label": "Workspace ID",
      value: settings.workspaceID || "",
      autocomplete: "off",
      spellcheck: false,
    });
    const audioKey = el("input", {
      type: "password",
      "aria-label": "音频 API Key",
      autocomplete: "new-password",
      placeholder: credentials.hasAPIKey
        ? "已安全保存，留空则不修改"
        : "输入音频 API Key",
      disabled: !credentials.encryptionAvailable,
    });
    const chatKey = el("input", {
      type: "password",
      "aria-label": "编剧 API Key",
      autocomplete: "new-password",
      placeholder: credentials.hasChatKey
        ? "已安全保存，留空则不修改"
        : "输入编剧 API Key",
      disabled: !credentials.encryptionAvailable,
    });
    const url = el("input", {
      "aria-label": "编剧 API Base URL",
      value: settings.chatBaseURL || "https://api.deepseek.com/v1",
      spellcheck: false,
    });
    const model = el("input", {
      "aria-label": "编剧模型",
      value: settings.chatModel || "deepseek-v4.1-flash",
      spellcheck: false,
    });
    const submit = button(
      "保存设置",
      async () => {
        submit.disabled = true;
        try {
          const data = {
            workspaceID: workspace.value.trim(),
            chatBaseURL: url.value.trim(),
            chatModel: model.value.trim(),
          };
          if (audioKey.value.trim()) data.apiKey = audioKey.value.trim();
          if (chatKey.value.trim()) data.chatAPIKey = chatKey.value.trim();
          const result = await api.saveSettings(data);
          updateState(result);
          audioKey.value = "";
          chatKey.value = "";
          audioKey.placeholder = state.credentials.hasAPIKey
            ? "已安全保存，留空则不修改"
            : "输入音频 API Key";
          chatKey.placeholder = state.credentials.hasChatKey
            ? "已安全保存，留空则不修改"
            : "输入编剧 API Key";
          toast("设置已保存");
        } finally {
          submit.disabled = false;
        }
      },
      "primary",
    );
    $("content").replaceChildren(
      el(
        "div",
        { class: "settings-grid" },
        el(
          "div",
          { class: "settings-form" },
          el("h2", {}, "音频生成服务"),
          field("Workspace ID", workspace, "Qwen Audio Next 所属工作空间"),
          field("音频 API Key", audioKey, "密钥不会回显，留空保留已保存的密钥"),
          el("div", { class: "divider" }),
          el("h2", {}, "AI 编剧"),
          field(
            "编剧 API Base URL",
            url,
            "使用 HTTPS 的 OpenAI 兼容接口；对话将发送到此服务",
          ),
          field("编剧模型", model),
          field("编剧 API Key", chatKey),
          !credentials.encryptionAvailable
            ? el(
                "p",
                { class: "warning" },
                "系统加密服务不可用。密钥保存已禁用，不会以明文方式降级存储。",
              )
            : null,
          el("div", { class: "row" }, submit),
        ),
        el(
          "aside",
          { class: "settings-note" },
          el("h3", {}, "一处设置，安心创作"),
          el(
            "p",
            {},
            "API Key 通过 Windows 系统加密保存在本机。创作界面只能读取密钥是否已配置。",
          ),
          el("br"),
          el("h3", {}, "关于生成费用"),
          el(
            "p",
            {},
            "生成会向音频服务发送脚本与明确选择的参考音色。每个候选都会产生一次独立调用，确认前会展示完整内容。",
          ),
          el("br"),
          el("h3", {}, "你的本地作品"),
          el(
            "p",
            {},
            "草稿、模板和任务历史保存在本机。输出目录由你选择；回收站可恢复，不会永久删除文件。",
          ),
          el("br"),
          el("p", {}, "Qwen Audio Studio " + (state.version || "")),
        ),
      ),
    );
  }
  function parseScripts(text) {
    const result = [];
    const regex = /```qwen-script\s*\n([\s\S]*?)```/g;
    let match;
    while ((match = regex.exec(text))) {
      let name = "未命名灵感脚本",
        mode = "auto";
      const body = [];
      for (const line of match[1].split("\n")) {
        const title = line.match(/^\s*\[标题\]\s*[:：]\s*(.*)$/);
        const modeLine = line.match(/^\s*\[模式\]\s*[:：]\s*(.*)$/);
        if (title) name = title[1].trim() || name;
        else if (modeLine) {
          const value = modeLine[1].trim();
          mode =
            Object.entries(modes).find(
              ([key, title]) => key === value || title === value,
            )?.[0] || "auto";
        } else body.push(line);
      }
      const prompt = body.join("\n").trim();
      if (prompt) result.push({ name, mode, prompt });
    }
    return result;
  }
  function renderChat() {
    $("page-actions").replaceChildren(
      button(
        "清空对话",
        () => {
          openModal(
            "清空对话？",
            el("p", {}, "这会清空本机保存的编剧对话，已导入的草稿不会改变。"),
            [
              button("取消", closeModal),
              button(
                "确认清空",
                async () => {
                  await api.clearChat();
                  closeModal();
                },
                "danger",
              ),
            ],
          );
        },
        "quiet",
      ),
    );
    const input = el("textarea", {
      "aria-label": "创作需求",
      placeholder:
        "说说你想创作什么。一个场景、一段对白，或者一个还不完整的念头…",
      value: chatInput,
      maxLength: 10000,
      oninput: (event) => {
        chatInput = event.target.value;
      },
    });
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
        event.preventDefault();
        sendChat();
      }
    });
    $("content").replaceChildren(
      el(
        "div",
        { class: "chat-view" },
        el("div", { class: "chat-messages", id: "chat-messages" }),
        el(
          "div",
          { class: "chat-compose" },
          input,
          el(
            "div",
            { class: "row" },
            el("small", {}, "发送至已配置的编剧服务 · Ctrl + Enter 发送"),
            button("发送", sendChat, "primary", {
              id: "chat-send",
              disabled: chatBusy,
            }),
          ),
        ),
      ),
    );
    renderMessages();
  }
  function renderMessages() {
    const container = $("chat-messages");
    if (!container) return;
    const messages = state.chatMessages || [];
    container.replaceChildren();
    if (!messages.length)
      container.append(
        el(
          "div",
          { class: "chat-welcome" },
          el("h2", {}, "好故事，从一个念头开始"),
          el("p", {}, "把你的灵感告诉我，一起写出有画面、有情绪的声音脚本。"),
          el(
            "div",
            { class: "suggestions" },
            [
              "雨夜书房双人播客",
              "15 秒咖啡产品广告",
              "车站里的悬疑广播剧",
              "奇幻酒馆的老店主",
            ].map((text) =>
              button(text, () => {
                chatInput = "请创作一段" + text + "，包含对白和环境音效。";
                renderChat();
                $("content").querySelector("textarea").focus();
              }),
            ),
          ),
        ),
      );
    for (const message of messages) {
      const text = message.content || message.text || "";
      container.append(
        el(
          "article",
          {
            class:
              "chat-message " +
              (message.role === "user" ? "user" : "assistant"),
          },
          el(
            "span",
            { class: "speaker" },
            message.role === "user" ? "你" : "AI 编剧",
          ),
          el("pre", {}, text),
          message.role !== "user"
            ? parseScripts(text).map((script) =>
                button(
                  "导入创作台",
                  () => replaceDraft(script),
                  "small primary",
                ),
              )
            : null,
        ),
      );
    }
    if (chatBusy)
      container.append(
        el("div", { class: "chat-pending" }, "正在构思你的声音故事…"),
      );
    container.scrollTop = container.scrollHeight;
  }
  async function sendChat() {
    if (chatBusy) return;
    const text = chatInput.trim();
    if (!text) return;
    chatBusy = true;
    const button = $("chat-send");
    if (button) button.disabled = true;
    renderMessages();
    try {
      const result = await api.chat({ text });
      state.chatMessages = result.messages;
      chatInput = "";
      if (page === "chat") renderChat();
    } finally {
      chatBusy = false;
      if (page === "chat") {
        if ($("chat-send")) $("chat-send").disabled = false;
        renderMessages();
      }
    }
  }
  function openReferences() {
    const list = el("div", { id: "reference-list" });
    const body = el(
      "div",
      { class: "stack" },
      el(
        "p",
        { class: "notice" },
        "最多绑定 3 段参考音色。请只使用你拥有使用权且获得授权的声音。编号固定，移除其他音色不会重新编号。",
      ),
      button("导入音频文件", importReference, "primary"),
      list,
    );
    openModal("参考音色", body, [button("完成", closeModal)]);
    const render = () => {
      list.replaceChildren(
        ...(state.references || []).map((ref) => {
          const used = draft.bindings.find((b) => b.referenceID === ref.id);
          let slot =
            used?.slot ||
            [1, 2, 3].find((n) => !draft.bindings.some((b) => b.slot === n)) ||
            1;
          return el(
            "div",
            { class: "reference-row" },
            button(
              "▶",
              () => playItem("reference", ref.id, ref.name),
              "play-circle",
              { "aria-label": "试听 " + ref.name },
            ),
            el(
              "div",
              { class: "reference-info" },
              el("strong", {}, ref.name),
              el(
                "small",
                {},
                Number(ref.duration).toFixed(1) + " 秒 · 本地参考音色",
              ),
            ),
            select(
              "绑定编号 " + ref.name,
              [
                [1, "@voice1"],
                [2, "@voice2"],
                [3, "@voice3"],
              ],
              slot,
              (value) => {
                slot = Number(value);
              },
            ),
            button(
              used ? "更新绑定" : "绑定",
              () => {
                const occupied = draft.bindings.find(
                  (b) => b.slot === slot && b.referenceID !== ref.id,
                );
                if (occupied)
                  throw new Error(
                    "@voice" + slot + " 已被其他音色使用，请选择空闲编号",
                  );
                draft.bindings = draft.bindings.filter(
                  (b) => b.referenceID !== ref.id,
                );
                draft.bindings.push({
                  referenceID: ref.id,
                  alias: ref.name,
                  slot,
                });
                draft.bindings.sort((a, b) => a.slot - b.slot);
                changed();
                renderBindings();
                render();
              },
              "small",
            ),
            button(
              "移除",
              () => {
                openModal(
                  "移除参考音色？",
                  el(
                    "p",
                    {},
                    "移除「" +
                      ref.name +
                      "」后，当前草稿中的对应绑定也会移除。正在使用中的参考文件不能移除。",
                  ),
                  [
                    button("取消", openReferences),
                    button(
                      "确认移除",
                      async () => {
                        await api.removeReference(ref.id);
                        draft.bindings = draft.bindings.filter(
                          (b) => b.referenceID !== ref.id,
                        );
                        changed();
                        renderBindings();
                        openReferences();
                      },
                      "danger",
                    ),
                  ],
                );
              },
              "quiet small",
            ),
          );
        }),
      );
      if (!state.references?.length)
        list.append(
          el(
            "div",
            { class: "empty-state" },
            "还没有参考音色，导入一个声音开始吧",
          ),
        );
    };
    render();
  }
  async function importReference() {
    const picked = await api.pickReference();
    if (!picked) return;
    toast("正在解析本地音频…");
    const buffer = await AudioTools.decode(picked.data);
    openCrop(picked.name, buffer);
  }
  function openCrop(name, buffer) {
    const start = el("input", {
      type: "number",
      "aria-label": "片段开始秒数",
      min: 0,
      max: buffer.duration,
      step: 0.01,
      value: 0,
    });
    const end = el("input", {
      type: "number",
      "aria-label": "片段结束秒数",
      min: 0,
      max: buffer.duration,
      step: 0.01,
      value: buffer.duration.toFixed(2),
    });
    const title = el("input", {
      "aria-label": "参考音色名称",
      value: name.replace(/\.[^.]+$/, ""),
      maxLength: 100,
    });
    const canvas = el("canvas", {
      class: "waveform",
      width: 1000,
      height: 140,
      "aria-label": "源音频波形",
    });
    const summary = el("p", { class: "crop-duration" });
    const error = el("p", { class: "error-text", role: "alert" });
    let valid = false;
    const update = () => {
      const a = Number(start.value),
        b = Number(end.value);
      valid =
        start.value !== "" &&
        end.value !== "" &&
        Number.isFinite(a) &&
        Number.isFinite(b) &&
        a >= 0 &&
        b > a &&
        b <= buffer.duration + 0.005 &&
        b - a <= 30;
      summary.textContent =
        "源音频 " +
        buffer.duration.toFixed(2) +
        " 秒 · 已选 " +
        Math.max(0, b - a).toFixed(2) +
        " 秒";
      error.textContent = valid
        ? ""
        : "请明确选择不超过 30 秒的有效片段，应用不会自动裁剪";
      save.disabled = !valid;
      preview.disabled = !valid;
      AudioTools.drawWaveform(
        canvas,
        buffer,
        Math.max(0, a),
        Math.min(buffer.duration, b),
      );
    };
    start.addEventListener("input", update);
    end.addEventListener("input", update);
    const selectedBytes = () =>
      AudioTools.encodeSelection(
        buffer,
        Number(start.value),
        Math.min(buffer.duration, Number(end.value)),
      );
    const preview = button("试听所选片段", async () => {
      audioVersion++;
      await playBytes(
        selectedBytes(),
        "audio/wav",
        title.value + " · 裁剪试听",
        "crop-preview",
      );
    });
    const save = button(
      "保存参考音色",
      async () => {
        if (!valid) return;
        save.disabled = true;
        try {
          await api.saveReference({
            name: title.value.trim() || "参考音色",
            data: selectedBytes(),
          });
          if (currentAudioID === "crop-preview") stopAudio();
          openReferences();
          toast("参考音色已保存，请选择编号绑定到草稿");
        } finally {
          if (save.isConnected) save.disabled = false;
        }
      },
      "primary",
    );
    openModal(
      "选择参考音频片段",
      el(
        "div",
        { class: "stack" },
        field("参考音色名称", title),
        el(
          "p",
          { class: "notice" },
          "WAV / MP3 / M4A / OGG · 本地解码 · 保存为单声道 PCM16 WAV",
        ),
        canvas,
        summary,
        el(
          "div",
          { class: "two-fields" },
          field("开始（秒）", start),
          field("结束（秒）", end),
        ),
        error,
        preview,
      ),
      [button("取消", openReferences), save],
      () => {
        if (currentAudioID === "crop-preview") stopAudio();
      },
    );
    update();
  }
  document.addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "s") {
      event.preventDefault();
      saveNow().catch(showError);
    }
  });
  window.addEventListener("beforeunload", () => {
    if (currentAudioURL) URL.revokeObjectURL(currentAudioURL);
  });
  async function init() {
    if (!api)
      throw new Error("桌面连接未就绪，请通过 Qwen Audio Studio 启动应用");
    state = await api.bootstrap();
    draft = {
      name: "未命名作品",
      mode: "podcast",
      prompt: "",
      bindings: [],
      ...state.draft,
      params: { ...defaults, ...state.draft?.params },
    };
    draft.bindings = draft.bindings || [];
    api.onState(updateState);
    api.onBeforeClose?.(() => saveNow());
    $("version").textContent =
      "WINDOWS EDITION / " + (state.version || "0.1.0");
    navigate("create");
  }
  init().catch((error) => {
    $("content").replaceChildren(
      el(
        "div",
        { class: "empty-state" },
        el("strong", {}, "工作室暂时无法打开"),
        error.message,
      ),
    );
    showError(error);
  });
})();
