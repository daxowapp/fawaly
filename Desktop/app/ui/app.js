"use strict";

const invoke = (name, args) => window.__TAURI__.core.invoke(name, args);
const listen = (name, handler) => window.__TAURI__.event.listen(name, handler);

const ui = {
  data: null,
  arabic: false,
  page: "home",
  step: 0,
  busy: null,
  phases: {},
  browserUrl: null,
  issue: null,
  draft: null,
  mode: "important",
  region: "global",
  activity: null,
  link: null,
  skillsScope: "project",
  skillsDir: null,
  skills: null,
  daily: null,
  dailyFilter: "all",
  search: "",
  modal: null,
  apiForm: {},
  models: {},
};

/* ---------- Copy ---------- */

// Friendly workshop copy. Action labels, permissions and billing stay literal.
const VOICE = {
  "Welcome to Fawaly": ["أهلًا بيك في الفواعلي. الخوذ جاهزة!", "Welcome to Sudo Interns. Hard hats on."],
  "Set up your team and keep working with your primary agent.": ["وزّع الخوذ. الأساسي يقود، والفواعلي يشيلوا الشغل.", "Hand out the hard hats. Your primary leads; the interns get to work."],
  "Choose your primary, advisor, and workers": ["اختار الكبير، المستشار، واللي هيشيلوا الشغل", "Pick the lead, the second opinion, and the heavy lifters"],
  "Sign in using your browser": ["سجّل الدخول من المتصفح. ورق التعيين بسيط.", "Sign in through your browser. Minimal paperwork."],
  "Connect the team and return to your agent app": ["وصّل الفريق وارجع لأجنتك. هو عارف مكتبك.", "Connect the crew, then head back to your usual agent"],
  "Choose the services you want": ["مين نجيب له خوذة؟", "Who needs a hard hat?"],
  "Your team is ready to connect": ["الفريق واقف على الباب. نوصّله؟", "The crew is at the door. Ready to connect."],
  "Working…": ["بنظبّط الوردية…", "Getting the crew in order…"],
  "Ready to prepare": ["جاهز يستلم الخوذة", "Ready for a hard hat"],
  "Ready for sign-in": ["جاهز. ناقص كارت الدخول.", "Ready. Just needs a badge."],
  "Preparing…": ["بنجهّز العِدّة…", "Packing the toolbox…"],
  "Checking connection…": ["بننادي عليه… سامعنا؟", "Checking the line. Anyone home?"],
  "Please retry": ["المحاولة ما ظبطتش. نعيدها؟", "That did not stick. Please retry."],
  "Your agent plans. Fawaly executes.": ["الكبير يخطّط. والفواعلي يشيلوا الشغل.", "Your agent plans. The interns clock in."],
  "Set up your team, follow its work, and keep chatting with your primary agent.": ["جهّز الوردية، تابع الشغل، وكمّل مع الأساسي. القهوة لسه سخنة.", "Set up the crew, follow the work, and keep chatting with your primary. Coffee optional."],
  "Worker order and advisor policy": ["مين يشيل؟ وإمتى نسأل الكبير؟", "Who lifts first? When do we ask for backup?"],
  "Independent advice, primary decision": ["المستشار يقول رأيه. القرار عند الكبير.", "Second opinion. First-class accountability."],
  "Task results saved in this workshop.": ["دفتر الشغل والمراجعات. الذاكرة مش هنسيبها للصبيان.", "The work log and reviews. The interns cannot claim they forgot."],
  "No results match this search": ["البحث رجع فاضي. حتى الصبي دوّر تحت الترابيزة.", "No matches. We checked under the workbench too."],
  "The ledger is empty": ["دفتر الشغل لسه جديد. أول مهمة هتفك النحس.", "A fresh timesheet. The first task gets the honor."],
  "No consultations yet.": ["لسه مفيش استشارات. المشورة مش عيب.", "No consultations yet. Asking is allowed."],
  "Project skills, memory and instruction templates, with credit and overlap checks before installation.": ["عِدّة أحسن ودفتر ذاكرة. بالكريدت، ومن غير خناقة على التعليمات.", "A better toolbox and a memory notebook. Credits included; instruction pileups checked."],
  "Fresh tools and agent news. Original sources, practical next steps.": ["جديد البرمجة والوكلاء على القهوة. مصدر واضح وخطوة تتجرّب.", "Developer news for your coffee break. Original sources. Something useful to try."],
  "No headlines to show": ["الجرنال فاضي هنا. المطبعة مش في إضراب.", "No headlines here. The printing press is fine."],
  "Save for later": ["احفظه لبعد القهوة", "Save for the next coffee"],
  "Saved for later": ["محفوظة لبعد القهوة", "Saved for the next coffee"],
  "Prepare a team task": ["جهّز مهمة للوردية", "Brief the crew"],
  "Brief copied": ["الطلب اتنسخ. الصقه عند الأساسي يراجع المصدر ويخطّط التجربة. لسه محدش مسك الشاكوش.", "Brief copied. Paste it into your primary chat for source review and a trial plan. No hammers swung yet."],
  "Workshop language and storage.": ["لغة الورشة وحاجتها. كله في الدرج الصح.", "Workshop language and storage. A drawer for everything."],
  "Your accounts": ["الحسابات اللي حضرت الوردية. أضف مساعدًا وحدد له شغله.", "Accounts that showed up for the shift. Add an assistant and give it a job."],
  "Local activity": ["دفتر الحضور والشغل", "The local timesheet"],
  "Keys stay here": ["المفاتيح عندك. الشغل للخدمات اللي تختارها.", "Keys stay on this computer. Tasks go to your chosen services."],
};

function t(arabic, english) {
  const voice = VOICE[english];
  if (voice) return ui.arabic ? voice[0] : voice[1].replaceAll("Fawaly", "Sudo Interns");
  return ui.arabic ? arabic : english.replaceAll("Fawaly", "Sudo Interns");
}

/* ---------- DOM helper: text is always set as text, never parsed as HTML. ---------- */

function h(tag, props, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props || {})) {
    if (value === undefined || value === null || value === false) continue;
    if (key === "class") node.className = value;
    else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
    else if (key === "value") node.value = value;
    else if (key === "checked" || key === "disabled" || key === "selected") node[key] = Boolean(value);
    else node.setAttribute(key, value === true ? "" : value);
  }
  for (const child of children.flat(Infinity)) {
    if (child === undefined || child === null || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

const ICONS = {
  hammer: "M14 4l6 6-3 3-6-6zM11 7L3 15l3 3 8-8",
  home: "M3 11l9-8 9 8M5 10v10h14V10M10 20v-6h4v6",
  plug: "M9 3v5M15 3v5M7 8h10v4a5 5 0 01-10 0zM12 17v4",
  rules: "M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6zM9 12l2 2 4-4",
  chat: "M4 4h16v11H9l-5 4zM8 9h8M8 12h5",
  case: "M4 8h16v11H4zM9 8V5h6v3M4 13h16",
  spark: "M12 3l2 6 6 2-6 2-2 6-2-6-6-2 6-2z",
  paper: "M5 4h14v16H5zM8 8h8M8 12h8M8 16h5",
  list: "M6 4h12v17H6zM9 3h6v3H9zM9 11l2 2 4-4M9 17h6",
  gauge: "M4 18a8 8 0 1116 0M12 18l4-6",
  gear: "M12 8a4 4 0 100 8 4 4 0 000-8zM12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M19 5l-2 2M7 17l-2 2",
};

function icon(name) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "1.8");
  svg.setAttribute("stroke-linecap", "round");
  svg.setAttribute("stroke-linejoin", "round");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", ICONS[name]);
  svg.append(path);
  return svg;
}

const ltr = (value) => h("span", { class: "ltr", dir: "ltr" }, value);

let toastTimer;
function toast(message) {
  const node = document.getElementById("toast");
  node.textContent = message;
  node.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => node.classList.remove("show"), 5200);
}

function report(error) {
  toast(String(error));
}

/* ---------- Data ---------- */

function service(agent) {
  return ui.data.services.find((item) => item.agent === agent);
}

function label(agent) {
  return service(agent)?.label ?? agent;
}

function theme(appearance) {
  const dark = appearance === "dark" || (appearance !== "light" && matchMedia("(prefers-color-scheme: dark)").matches);
  document.documentElement.dataset.theme = dark ? "dark" : "light";
}

function applyLanguage() {
  document.documentElement.lang = ui.arabic ? "ar" : "en";
  document.documentElement.dir = ui.arabic ? "rtl" : "ltr";
  const title = ui.arabic ? "الفواعلي" : "Sudo Interns";
  document.title = title;
  window.__TAURI__?.window?.getCurrentWindow?.().setTitle(title).catch(() => {});
}

async function refresh() {
  ui.data = await invoke("bootstrap");
  ui.arabic = ui.data.state.arabic;
  applyLanguage();
  theme(ui.data.state.appearance);
}

async function setArabic(arabic) {
  await invoke("set_preferences", { arabic });
  await refresh();
  render();
}

async function run(name, action) {
  if (ui.busy) return;
  ui.busy = name;
  render();
  try {
    await action();
  } catch (error) {
    report(error);
  } finally {
    ui.busy = null;
    ui.browserUrl = null;
    render();
  }
}

function openLink(url) {
  invoke("open_link", { url }).catch(report);
}

async function copy(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const area = h("textarea", { value: text });
    document.body.append(area);
    area.select();
    const done = document.execCommand("copy");
    area.remove();
    return done;
  }
}

/* ---------- Shared pieces ---------- */

function languageButton() {
  return h("button", { class: "btn", onclick: () => setArabic(!ui.arabic), "data-testid": "language" }, ui.arabic ? "English" : "العربية");
}

function header(title, subtitle, art) {
  return h("div", { class: "header" }, h("div", {}, h("h1", {}, title), h("p", {}, subtitle)), art && h("img", { src: `assets/${art}.png`, alt: "" }));
}

function segmented(options, current, onChange, disabled) {
  return h(
    "div",
    { class: "segmented", role: "group" },
    options.map(([value, text]) =>
      h("button", { class: value === current ? "active" : "", disabled, "aria-pressed": String(value === current), onclick: () => onChange(value), "data-testid": `choice-${value}` }, text)
    )
  );
}

function busyRow(text) {
  return h("div", { class: "row" }, h("span", { class: "spin", "aria-hidden": "true" }), h("span", {}, text));
}

const BILLING = () => ({
  subscription: t("اشتراكك", "Your subscription"),
  provider_account: t("حسابك عند الخدمة (مدفوع)", "Your provider account (paid)"),
  local_endpoint: t("محلي على جهازك", "Local on this computer"),
});

/* ---------- Team editor ---------- */

function selectableAgents() {
  return ui.data.services.filter((item) => item.native || item.configured || ["openrouter", "deepseek", "minimax", "zai", "ollama", "lmstudio"].includes(item.agent)).map((item) => item.agent);
}

function teamEditor() {
  const team = ui.draft;
  const others = selectableAgents().filter((agent) => agent !== team.primary);
  const workers = others.filter((agent) => agent !== team.advisor);
  return h(
    "div",
    { class: "stack" },
    h("h2", {}, t("اختار فريقك", "Choose your team")),
    h("p", { class: "muted" }, t("هتكمّل شغلك في تطبيق أجنتك المعتاد. الأساسي يقود الشغل، والمستشار يديله رأي مستقل، والفواعلي ينفّذوا الأجزاء اللي يفوّضها لهم.", "Keep working in your usual agent app. Your primary leads the work, an advisor provides an independent opinion, and workers handle delegated tasks.")),
    h("h3", {}, t("الوكيل الرئيسي", "Primary agent")),
    segmented(
      [["codex", "Codex"], ["claude", "Claude Code"]],
      team.primary,
      (value) => {
        team.primary = value;
        team.workers = team.workers.filter((agent) => agent !== value);
        if (team.advisor === value) team.advisor = value === "codex" ? "claude" : "codex";
        team.workers = team.workers.filter((agent) => agent !== team.advisor);
        render();
      }
    ),
    h(
      "label",
      { class: "field" },
      t("مستشاره", "Its advisor"),
      h(
        "select",
        {
          "data-testid": "advisor",
          onchange: (event) => {
            team.advisor = event.target.value || null;
            team.workers = team.workers.filter((agent) => agent !== team.advisor);
            if (team.advisor && ui.mode === "off") ui.mode = "important";
            render();
          },
        },
        h("option", { value: "", selected: !team.advisor }, t("من غير مستشار حاليًا", "No advisor for now")),
        others.map((agent) => h("option", { value: agent, selected: agent === team.advisor }, label(agent)))
      )
    ),
    team.advisor &&
      h(
        "label",
        { class: "field" },
        t("المستشار يتدخل", "Advisor involvement"),
        h(
          "select",
          { onchange: (event) => { ui.mode = event.target.value; } },
          [["important", t("قبل الخطط والقرارات المهمة", "Before plans and important decisions")], ["on_request", t("لما أطلب بس", "Only when I ask")], ["off", t("متوقف حاليًا", "Paused for now")]].map(([value, text]) => h("option", { value, selected: ui.mode === value }, text))
        )
      ),
    h("h3", {}, t("الفواعلي", "Workers")),
    workers.map((agent) =>
      h(
        "label",
        { class: "check" },
        h("input", {
          type: "checkbox",
          checked: team.workers.includes(agent),
          "data-testid": `worker-${agent}`,
          onchange: (event) => {
            team.workers = team.workers.filter((value) => value !== agent);
            if (event.target.checked) team.workers.push(agent);
            render();
          },
        }),
        h("span", {}, label(agent)),
        h("span", { class: "muted small" }, BILLING()[service(agent).billing])
      )
    )
  );
}

/* ---------- Assistant connections ---------- */

function phaseText(agent) {
  const phase = ui.phases[agent];
  const item = service(agent);
  if (phase === "preparing") return t("جاري التجهيز…", "Preparing…");
  if (phase === "signing") return t("كمّل تسجيل الدخول في المتصفح", "Complete sign-in in your browser");
  if (phase === "verifying") return t("بنتحقق من الربط…", "Checking connection…");
  if (phase === "failed") return t("محتاج محاولة تانية", "Please retry");
  if (item.ready) return item.native ? t("تم التحقق من تسجيل الدخول", "Sign-in verified") : t("إعداد الخدمة محفوظ ومفعّل", "Service configured and enabled");
  if (item.native && !item.installed) return t("جاهزة للتجهيز", "Ready to prepare");
  return item.native ? t("جاهزة لتسجيل الدخول", "Ready for sign-in") : t("محتاج مفتاح وموديل", "Needs a key and model");
}

function statusLine(agent) {
  const phase = ui.phases[agent];
  const active = ["preparing", "signing", "verifying"].includes(phase);
  return h(
    "div",
    { class: "status-line" },
    h("div", { class: "row" }, active && h("span", { class: "spin", "aria-hidden": "true" }), h("strong", {}, label(agent))),
    h("span", { class: `badge ${service(agent).ready ? "good" : phase === "failed" ? "bad" : ""}` }, phaseText(agent))
  );
}

async function prepareServices(agents) {
  for (const agent of agents) {
    if (!service(agent).native) continue;
    ui.phases[agent] = service(agent).installed ? "verifying" : "preparing";
    render();
    try {
      await invoke("prepare_service", { agent });
      delete ui.phases[agent];
    } catch (error) {
      ui.phases[agent] = "failed";
      await refresh();
      throw error;
    }
    await refresh();
    render();
  }
}

async function connectNative(agent) {
  ui.phases[agent] = "signing";
  try {
    await invoke("sign_in", { agent, region: ui.region });
    delete ui.phases[agent];
    toast(t(`${label(agent)} اتربط.`, `${label(agent)} connected.`));
  } catch (error) {
    ui.phases[agent] = "failed";
    report(error);
  }
  await refresh();
}

function nativeControls(agent) {
  const item = service(agent);
  return h(
    "div",
    { class: "stack" },
    statusLine(agent),
    agent === "kimi" && !item.ready && h("label", { class: "field" }, t("حساب Kimi", "Kimi account"), h("select", { onchange: (event) => { ui.region = event.target.value; } }, h("option", { value: "global", selected: ui.region === "global" }, t("دولي (kimi.ai)", "Global (kimi.ai)")), h("option", { value: "mainland-cn", selected: ui.region === "mainland-cn" }, "kimi.com"))),
    h(
      "div",
      { class: "row" },
      item.ready
        ? h("button", { class: "btn", disabled: ui.busy, onclick: () => run(`out-${agent}`, async () => { await invoke("sign_out", { agent }); await refresh(); }) }, t("تسجيل خروج", "Sign out"))
        : h("button", { class: "btn primary", disabled: ui.busy || !item.installed, "data-testid": `connect-${agent}`, onclick: () => run(`in-${agent}`, () => connectNative(agent)) }, `${t("اربط", "Connect")} ${item.label}`),
      ui.busy === `in-${agent}` && h("button", { class: "btn", onclick: () => invoke("cancel_operation") }, t("إلغاء", "Cancel")),
      ui.busy === `in-${agent}` && ui.browserUrl && h("button", { class: "btn", onclick: () => openLink(ui.browserUrl) }, t("افتح صفحة تسجيل الدخول", "Open sign-in page"))
    )
  );
}

const KEY_LINKS = {
  zai: "https://z.ai/manage-apikey/apikey-list",
  minimax: "https://platform.minimax.io/user-center/basic-information/interface-key",
  deepseek: "https://platform.deepseek.com/api_keys",
  openrouter: "https://openrouter.ai/settings/keys",
};

function apiForm(agent) {
  const item = service(agent);
  const form = (ui.apiForm[agent] ||= { model: item.model || "", key: "", endpoint: item.endpoint || "", query: "", oauth: false });
  const models = ui.models[agent] || [];
  const custom = ["anthropicAPI", "openAIAPI"].includes(agent);
  const query = form.query.toLowerCase();
  const shown = models.filter((model) => model.toLowerCase().includes(query)).slice(0, 80);
  const save = (extra) =>
    invoke("save_assistant", { input: { agent, model: form.model, endpoint: custom ? form.endpoint : null, key: form.key || null, usePendingOpenrouter: form.oauth, ...extra } });
  return h(
    "div",
    { class: "stack" },
    statusLine(agent),
    h("p", { class: "muted small" }, BILLING()[item.billing]),
    agent === "openrouter" &&
      h(
        "div",
        { class: "row" },
        h("button", { class: "btn primary", disabled: ui.busy, "data-testid": "openrouter-browser", onclick: () => run("openrouter", async () => { await invoke("openrouter_sign_in"); form.oauth = true; ui.models[agent] = await invoke("list_models", { agent }); toast(t("التفويض وصل. اختار الموديل واحفظ.", "Authorized. Choose a model and save.")); }) }, t("اربط من المتصفح", "Connect in browser")),
        ui.busy === "openrouter" && h("button", { class: "btn", onclick: () => invoke("cancel_operation") }, t("إلغاء", "Cancel")),
        form.oauth && h("span", { class: "badge good" }, t("التفويض جاهز", "Authorization ready"))
      ),
    !item.local && !form.oauth && h("label", { class: "field" }, t("مفتاح الخدمة", "Service key"), h("input", { type: "password", autocomplete: "off", dir: "ltr", placeholder: item.configured ? t("محفوظ في مخزن النظام", "Saved in the system store") : "", oninput: (event) => { form.key = event.target.value; } })),
    KEY_LINKS[agent] && !form.oauth && h("button", { class: "btn", style: "align-self:flex-start", onclick: () => openLink(KEY_LINKS[agent]) }, t("هات مفتاح من الموقع الرسمي", "Get a key from the official site")),
    custom && h("label", { class: "field" }, t("عنوان الخدمة", "Endpoint"), h("input", { type: "text", dir: "ltr", value: form.endpoint, oninput: (event) => { form.endpoint = event.target.value; } })),
    h("label", { class: "field" }, t("الموديل", "Model"), h("input", { type: "text", dir: "ltr", value: form.model, "data-testid": `model-${agent}`, oninput: (event) => { form.model = event.target.value; } })),
    h(
      "div",
      { class: "row" },
      h("button", { class: "btn", disabled: ui.busy, onclick: () => run(`models-${agent}`, async () => { ui.models[agent] = await invoke("list_models", { agent, key: form.key || null }); if (!ui.models[agent].length) toast(t("مفيش موديلات متاحة.", "No models were listed.")); }) }, t("هات قائمة الموديلات", "Load models")),
      h("button", { class: "btn primary", disabled: ui.busy, "data-testid": `save-${agent}`, onclick: () => run(`save-${agent}`, async () => { await save(); form.key = ""; form.oauth = false; await refresh(); toast(t("اتحفظ.", "Saved.")); }) }, t("احفظ", "Save")),
      h("button", { class: "btn", disabled: ui.busy, title: t("بيبعت طلب حقيقي ممكن يتحسب عليك.", "Sends one real request, which may be billed."), onclick: () => run(`test-${agent}`, async () => { await save(); await refresh(); const reply = await invoke("test_assistant", { agent }); toast(t(`الرد: ${reply}`, `Reply: ${reply}`)); }) }, t("احفظ وجرّب (طلب مدفوع)", "Save & test (paid request)"))
    ),
    models.length > 0 &&
      h(
        "div",
        { class: "stack" },
        h("input", { type: "search", dir: "ltr", value: form.query, placeholder: t("دوّر على موديل", "Search models"), "aria-label": t("دوّر على موديل", "Search models"), oninput: (event) => { form.query = event.target.value; render(); document.querySelector('input[type="search"]')?.focus(); } }),
        h("select", { size: 6, dir: "ltr", "aria-label": t("اختار موديل", "Choose a model"), onchange: (event) => { form.model = event.target.value; render(); } }, shown.map((model) => h("option", { value: model, selected: model === form.model }, model))),
        agent === "openrouter" && h("p", { class: "muted small" }, t("بنعرض الموديلات النصية اللي بتدعم الأدوات بس. الطلبات بتستخدم رصيدك على OpenRouter ومن غير تحويل تلقائي لمزوّد تاني.", "Only text models that support tools are shown. Requests use your OpenRouter credits, with provider fallback turned off."))
      )
  );
}

function connectionList(agents) {
  return agents.map((agent) => h("div", { class: "card" }, service(agent).native ? nativeControls(agent) : apiForm(agent)));
}

/* ---------- Onboarding ---------- */

function teamReady() {
  const team = ui.draft;
  if (!team) return false;
  const supporters = [team.advisor, ...team.workers].filter(Boolean);
  return supporters.every((agent) => service(agent).ready) && service(team.primary).installed;
}

function onboarding() {
  const editing = ui.data.state.onboardingVersion != null;
  const team = ui.draft;
  const natives = team ? [...new Set([team.primary, team.advisor, ...team.workers].filter((agent) => agent && service(agent).native))] : [];
  const supporters = team ? [team.advisor, ...team.workers].filter(Boolean) : [];
  const steps = [
    () => [
      h("img", { class: "onboard-art", src: "assets/crew-home-v2.png", alt: "" }),
      h("ul", { class: "steps" }, h("li", {}, t("اختار الأساسي والمستشار والفواعلي", "Choose your primary, advisor, and workers")), h("li", {}, t("سجّل الدخول في المتصفح", "Sign in using your browser")), h("li", {}, t("وصّل الفريق وارجع لتطبيق أجنتك", "Connect the team and return to your agent app"))),
      h("p", { class: "muted small" }, t("الفواعلي هيجهّز الربط بنفسه. كل خدمة هتطلب منك تسجيل الدخول في صفحتها الرسمية أو مفتاحك. بيانات الدخول الخاصة بالفواعلي بتتحفظ بشكل مستقل.", "Fawaly handles the setup. Each service asks you to sign in on its official page or use your own key. Fawaly keeps its service sign-ins separate.")),
    ],
    () => [teamEditor()],
    () => [
      h("h2", {}, t("اختار الخدمات اللي هتستخدمها", "Choose the services you want")),
      natives.map((agent) => statusLine(agent)),
      h("p", { class: "muted small" }, t("لو خدمة ناقصة، هننزّل نسختها الرسمية ونتحقق من بصمتها. التجهيز جوّه حسابك على الجهاز ومش محتاج صلاحيات مدير.", "Missing services are downloaded from their official source and checked against their published checksum. Setup stays in your account and does not need administrator rights.")),
    ],
    () => [
      h("h2", {}, t("اربط حسابات فريقك", "Connect your team's accounts")),
      h("p", { class: "muted" }, t("الأساسي هيستخدم حسابه في تطبيقه المعتاد. اربط هنا المستشار والفواعلي اللي اخترتهم.", "Your primary uses its account in its usual app. Connect your chosen advisor and workers here.")),
      connectionList(supporters),
    ],
    () => [
      h("h2", {}, t("فريقك جاهز للربط", "Your team is ready to connect")),
      h("div", {}, h("strong", {}, `${t("الأساسي", "Primary")} · ${label(team.primary)}`)),
      supporters.map((agent) => statusLine(agent)),
      h("p", { class: "muted" }, t(`هنوصّل الفريق بإعدادات ${label(team.primary)}. بعد الربط افتح محادثة جديدة في تطبيق أجنتك، ولو الفريق ما ظهرش أعد فتح التطبيق. الأجنت ممكن يطلب موافقتك على استخدام الفريق.`, `We'll connect the team in ${label(team.primary)}'s settings. Start a new chat afterward. If the team does not appear, reopen your agent app. Your agent may ask you to approve team tools.`)),
      ui.issue && h("div", { class: "notice" }, ui.issue),
    ],
  ];

  const next = {
    0: [t("ابدأ الإعداد", "Start setup"), () => { ui.draft = ui.draft || { primary: "codex", advisor: "claude", workers: [] }; ui.step = 1; render(); }],
    1: [
      t("جهّز الفريق", "Prepare team"),
      () =>
        run("save-team", async () => {
          await invoke("save_team", { team: ui.draft, mode: ui.draft.advisor ? ui.mode : "off" });
          await refresh();
          ui.step = 2;
        }),
    ],
    2: [t("جهّز الخدمات", "Prepare services"), () => run("prepare", async () => { await prepareServices(natives); ui.step = 3; })],
    3: [t("التالي", "Continue"), () => { ui.step = 4; render(); }, !teamReady()],
    4: [
      `${t("وصّل الفريق بـ", "Connect team to ")}${team ? label(team.primary) : ""}`,
      () =>
        run("connect", async () => {
          ui.issue = null;
          try {
            await invoke("connect_team");
          } catch (error) {
            ui.issue = String(error);
            return;
          }
          await invoke("finish_onboarding");
          await refresh();
          ui.draft = null;
          ui.step = 0;
          goto("home");
          toast(t("الفريق اتوصّل. افتح محادثة جديدة في أجنتك.", "Team connected. Start a new chat in your agent."));
        }),
      !team || !teamReady(),
    ],
  };
  const [text, action, blocked] = next[ui.step];
  const canExit = editing || ui.step > 0;
  return h(
    "div",
    { class: "onboard" },
    h(
      "div",
      { class: "row between" },
      h("div", {}, h("h1", {}, editing ? t("عدّل فريقك", "Edit your team") : t("أهلًا بيك في الفواعلي", "Welcome to Fawaly")), h("p", { class: "muted" }, t("جهّز فريقك، وكمّل شغلك مع أجنتك الأساسي.", "Set up your team and keep working with your primary agent."))),
      h("div", { class: "row" }, h("span", { class: "muted small", dir: "ltr" }, `${ui.step + 1} / 5`), languageButton())
    ),
    h("div", { class: "progress", role: "progressbar", "aria-valuemin": "1", "aria-valuemax": "5", "aria-valuenow": String(ui.step + 1) }, h("span", { style: `width:${((ui.step + 1) / 5) * 100}%` })),
    h("div", { class: "onboard-scroll" }, steps[ui.step]()),
    h(
      "div",
      { class: "row between" },
      h(
        "div",
        { class: "row" },
        ui.busy ? busyRow(t("لحظات…", "Working…")) : ui.step > 0 && h("button", { class: "btn", onclick: () => { ui.step -= 1; render(); } }, t("رجوع", "Back")),
        ui.busy && h("button", { class: "btn", onclick: () => invoke("cancel_operation") }, t("إلغاء", "Cancel"))
      ),
      h(
        "div",
        { class: "row" },
        canExit && !ui.busy && h("button", { class: "btn", "data-testid": "skip-setup", onclick: () => run("finish", async () => { await invoke("finish_onboarding"); await refresh(); ui.draft = null; ui.step = 0; ui.page = "home"; }) }, editing ? t("إلغاء التعديل", "Cancel changes") : t("كمّل الإعداد بعدين", "Finish setup later")),
        h("button", { class: "btn primary", disabled: Boolean(ui.busy) || blocked, onclick: action, "data-testid": "next" }, text)
      )
    )
  );
}

/* ---------- Pages ---------- */

const PAGES = () => [
  ["home", "home", t("الرئيسية", "Home")],
  ["connection", "plug", t("ربط الوكيل الرئيسي", "Primary connection")],
  ["rules", "rules", t("قواعد التفويض", "Delegation rules")],
  ["advisor", "chat", t("المستشار", "Advisor")],
  ["assistants", "case", t("المساعدون والاشتراكات", "Assistants & plans")],
  ["skills", "spark", "Skills"],
  ["daily", "paper", t("أخبار المطوّرين", "Developer Daily"), true],
  ["tasks", "list", t("المهام والمراجعات", "Tasks & reviews")],
  ["usage", "gauge", t("الاستخدام والحدود", "Usage & limits")],
  ["settings", "gear", t("الإعدادات", "Settings")],
];

const DESCRIPTIONS = () => ({
  connection: t("ربط الفريق بـCodex أو Claude Code", "Connect the team to Codex or Claude Code"),
  rules: t("Worker order and advisor policy", "Worker order and advisor policy"),
  advisor: t("Independent advice, primary decision", "Independent advice, primary decision"),
  assistants: t("الحسابات والمفاتيح والموديلات", "Accounts, keys and models"),
  skills: t("عِدّة وذاكرة لفريقك", "Tools and memory for your crew"),
  daily: t("Fresh tools and agent news. Original sources, practical next steps.", "Fresh tools and agent news. Original sources, practical next steps."),
});

function goto(page) {
  ui.page = page;
  if (["home", "tasks", "advisor", "usage"].includes(page)) loadActivity();
  if (page === "connection" || page === "home") loadLink();
  if (page === "skills") loadSkills();
  if (page === "daily") loadDaily(false);
  render();
}

async function loadActivity() {
  try {
    ui.activity = await invoke("activity");
    render();
  } catch (error) {
    report(error);
  }
}

async function loadLink() {
  try {
    ui.link = await invoke("connection_status");
    render();
  } catch {
    ui.link = { linked: false, unreadable: true };
    render();
  }
}

function statusLabel(status) {
  return (
    { running: t("شغّال", "Running"), completed: t("خلصت", "Completed"), needs_handoff: t("محتاج مراجعة الأساسي", "Needs primary review"), cancelled: t("اتلغت", "Cancelled"), reviewed: t("اتراجعت واتقبلت", "Reviewed and accepted"), changes_requested: t("محتاجة تعديل", "Changes requested"), rejected: t("مرفوضة بعد المراجعة", "Rejected after review") }[status] || t("ما اكتملتش", "Failed")
  );
}

function confinementLabel(value) {
  return (
    {
      app_enforced: t("الملفات من أدوات التطبيق فقط", "Files through the app's tools only"),
      landlock_git_monitored: t("محصور جوّه المشروع، و.git تحت المراقبة", "Limited to the project; .git monitored"),
      tool_level: t("محدود بإعدادات الأداة، مش النظام", "Limited by the tool's settings, not the OS"),
      unconfined_by_choice: t("من غير حدود (باختيارك)", "No boundary (your choice)"),
      no_project_access: t("نصي بس، من غير وصول للمشروع", "Text only, no project access"),
    }[value] || value
  );
}

function jobCard(job) {
  const review = job.reviews?.[job.reviews.length - 1];
  return h(
    "details",
    { class: "card" },
    h("summary", {}, job.title),
    h("div", { class: "row" }, h("span", { class: "muted small" }, label(job.worker)), h("span", { class: `badge ${job.status === "reviewed" ? "good" : ""}` }, statusLabel(job.status)), job.confinement && h("span", { class: "badge" }, confinementLabel(job.confinement))),
    job.gitChanges?.length > 0 && h("div", { class: "notice" }, t("اتغيّرت ملفات جوّه .git أثناء المهمة. راجعها.", "Files inside .git changed during this job. Please review them."), h("div", { class: "pre ltr", dir: "ltr" }, job.gitChanges.join("\n"))),
    job.result && h("div", { class: "pre" }, job.result),
    review && h("div", { class: "stack" }, h("strong", {}, `${t("مراجعة الأساسي", "Primary review")} · ${label(review.primary)}${review.score ? ` · ${review.score}/5` : ""}`), h("p", {}, review.summary), h("p", { class: "muted small" }, review.verification))
  );
}

function home() {
  const team = ui.data.state.team;
  const jobs = ui.activity?.jobs ?? [];
  const links = ["connection", "assistants", "rules", "advisor", "skills", "daily"];
  const names = Object.fromEntries(PAGES().map(([id, iconName, title]) => [id, [iconName, title]]));
  const description = DESCRIPTIONS();
  return [
    header(t("Your agent plans. Fawaly executes.", "Your agent plans. Fawaly executes."), t("Set up your team, follow its work, and keep chatting with your primary agent.", "Set up your team, follow its work, and keep chatting with your primary agent."), "crew-home-v2"),
    !team && h("div", { class: "notice" }, t("لسه ما اخترتش فريق.", "You have not chosen a team yet."), " ", h("button", { class: "btn", onclick: startEdit }, t("جهّز فريقك", "Set up your team"))),
    team && ui.link && !ui.link.linked && !ui.link.unreadable && h("div", { class: "notice" }, t("الفريق لسه مش متوصل بالأساسي.", "The team is not connected to your primary yet."), " ", h("button", { class: "btn", onclick: () => goto("connection") }, t("وصّله", "Connect it"))),
    h("div", { class: "grid" }, links.map((id) => h("button", { class: "card link-card", onclick: () => goto(id) }, icon(names[id][0]), h("div", { class: "grow" }, h("strong", {}, names[id][1]), h("div", { class: "muted small" }, description[id]))))),
    h("div", { class: "card" }, h("h2", {}, t("النشاط والمراجعة", "Activity & review")), jobs.length ? jobs.slice(0, 3).map(jobCard) : h("p", { class: "muted" }, t("The ledger is empty", "The ledger is empty"))),
  ];
}

function startEdit() {
  const team = ui.data.state.team;
  ui.draft = team ? structuredClone(team) : { primary: "codex", advisor: "claude", workers: [] };
  ui.mode = ui.data.state.advisors.mode === "on_request" && !team ? "important" : ui.data.state.advisors.mode;
  ui.step = 1;
  ui.page = "edit";
  render();
}

function connection() {
  const team = ui.data.state.team;
  const project = ui.data.state.projectDirectory;
  return [
    header(t("ربط الوكيل الرئيسي", "Primary connection"), t("كمّل شغلك في تطبيقك المعتاد. الفريق بيتوصل عن طريق MCP.", "Keep working in your usual app. The team joins through MCP."), "crew-connection-v2"),
    h(
      "div",
      { class: "card" },
      h("h2", {}, team ? label(team.primary) : t("لسه مفيش فريق", "No team yet")),
      ui.link && h("span", { class: `badge ${ui.link.linked ? "good" : "warn"}`, style: "align-self:flex-start" }, ui.link.linked ? t("متوصل", "Connected") : t("مش متوصل", "Not connected")),
      h(
        "div",
        { class: "row" },
        h("button", { class: "btn", onclick: startEdit }, t("عدّل الفريق", "Edit team")),
        team && h("button", { class: "btn primary", disabled: ui.busy, "data-testid": "reconnect", onclick: () => run("connect", async () => { await invoke("connect_team"); await loadLink(); toast(t("اتوصّل.", "Connected.")); }) }, t("وصّل الفريق", "Connect team")),
        team && ui.link?.linked && h("button", { class: "btn", disabled: ui.busy, onclick: () => run("disconnect", async () => { await invoke("disconnect_team"); await loadLink(); }) }, t("افصل الفريق", "Disconnect team"))
      )
    ),
    h(
      "div",
      { class: "card" },
      h("h2", {}, t("مشروع مسموح للعمال", "Project the workers may edit")),
      h("p", { class: "muted" }, t("العمال يقدروا يعدّلوا في الفولدرات اللي بتوافق عليها هنا بس.", "Workers can edit only the folders you approve here.")),
      project ? h("code", { class: "ltr", dir: "ltr" }, project) : h("p", { class: "muted" }, t("مفيش مشروع متحدد.", "No project selected.")),
      h("div", { class: "row" }, h("button", { class: "btn primary", disabled: ui.busy, onclick: () => run("project", async () => { await invoke("choose_project"); await refresh(); }) }, t("اختار فولدر المشروع", "Choose project folder"))),
      ui.data.workspaces.length > 0 && h("div", { class: "stack" }, ui.data.workspaces.map((path) => h("div", { class: "status-line" }, h("code", { class: "ltr", dir: "ltr" }, path), h("button", { class: "btn danger", onclick: () => run("revoke", async () => { await invoke("revoke_project", { path }); await refresh(); }) }, t("إلغاء السماح", "Revoke")))))
    ),
  ];
}

function rules() {
  const state = ui.data.state;
  const team = state.team;
  const policy = state.delegationPolicy || { timeoutSeconds: 900, orders: {} };
  const form = (ui.rulesForm ||= {
    mode: state.advisors.mode,
    maxRounds: state.advisors.maxRounds,
    timeoutMinutes: state.advisors.timeoutMinutes,
    timeoutSeconds: policy.timeoutSeconds,
    orders: structuredClone(policy.orders),
    allowPaidFallback: state.allowPaidFallback,
    allowUnconfinedWindowsKimi: state.allowUnconfinedWindowsKimi,
    allowUnconfinedLinuxWorkers: state.allowUnconfinedLinuxWorkers,
  });
  const kinds = [["general", t("عام", "General")], ["code", t("كود", "Code")], ["research", t("بحث", "Research")], ["review", t("مراجعة", "Review")]];
  const orderRows = (kind) => {
    const order = form.orders[kind]?.length ? form.orders[kind] : [...(team?.workers ?? [])];
    return order.map((agent, index) =>
      h(
        "div",
        { class: "status-line" },
        h("span", {}, `${index + 1}. ${label(agent)}`),
        h(
          "div",
          { class: "row" },
          h("span", { class: "muted small" }, BILLING()[service(agent).billing]),
          h("button", { class: "btn", disabled: index === 0, "aria-label": t("لفوق", "Move up"), onclick: () => { const next = [...order]; [next[index - 1], next[index]] = [next[index], next[index - 1]]; form.orders[kind] = next; render(); } }, "↑")
        )
      )
    );
  };
  return [
    header(t("قواعد التفويض", "Delegation rules"), t("Worker order and advisor policy", "Worker order and advisor policy"), "crew-shift"),
    !team && h("div", { class: "notice" }, t("اختار فريقك الأول.", "Choose your team first.")),
    h(
      "div",
      { class: "card" },
      h("h2", {}, t("المستشار", "Advisor")),
      h("label", { class: "field" }, t("يتدخل", "Involvement"), h("select", { onchange: (event) => { form.mode = event.target.value; } }, [["important", t("قبل الخطط والقرارات المهمة", "Before plans and important decisions")], ["on_request", t("لما أطلب بس", "Only when I ask")], ["off", t("متوقف", "Paused")]].map(([value, text]) => h("option", { value, selected: form.mode === value }, text)))),
      h("label", { class: "field" }, t("أقصى عدد جولات (1–5)", "Maximum rounds (1–5)"), h("input", { type: "number", min: 1, max: 5, value: form.maxRounds, oninput: (event) => { form.maxRounds = Number(event.target.value); } })),
      h("label", { class: "field" }, t("مهلة المستشار بالدقايق (1–10)", "Advisor timeout in minutes (1–10)"), h("input", { type: "number", min: 1, max: 10, value: form.timeoutMinutes, oninput: (event) => { form.timeoutMinutes = Number(event.target.value); } }))
    ),
    h(
      "div",
      { class: "card" },
      h("h2", {}, t("ترتيب العمال", "Worker order")),
      h("label", { class: "field" }, t("مهلة العامل بالثواني (1–3600)", "Worker timeout in seconds (1–3600)"), h("input", { type: "number", min: 1, max: 3600, value: form.timeoutSeconds, oninput: (event) => { form.timeoutSeconds = Number(event.target.value); } })),
      team?.workers.length ? kinds.map(([kind, text]) => h("details", {}, h("summary", {}, text), orderRows(kind))) : h("p", { class: "muted" }, t("مفيش عمال متعيّنين.", "No workers assigned."))
    ),
    h(
      "div",
      { class: "card" },
      h("h2", {}, t("الأذونات", "Permissions")),
      h("label", { class: "check" }, h("input", { type: "checkbox", checked: form.allowPaidFallback, "data-testid": "paid-fallback", onchange: (event) => { form.allowPaidFallback = event.target.checked; } }), t("اسمح باستخدام عامل مدفوع بديل لو العامل الأول مشغول", "Allow a paid worker to stand in when the first is unavailable")),
      h("p", { class: "muted small" }, t("مقفول افتراضيًا. لما يكون مقفول، الطلب بيقف ويسألك بدل ما يتحسب عليك. الوكيل مش يقدر يفتحه بنفسه.", "Off by default. While it is off, the request stops and asks you instead of billing you. An agent cannot turn this on.")),
      ui.data.platform.os === "windows" && h("label", { class: "check" }, h("input", { type: "checkbox", checked: form.allowUnconfinedWindowsKimi, onchange: (event) => { form.allowUnconfinedWindowsKimi = event.target.checked; } }), t("اسمح لـKimi يعدّل المشروع على ويندوز من غير حدود مؤكدة", "Let Kimi edit projects on Windows without a verified boundary")),
      ui.data.platform.os === "linux" && h("label", { class: "check" }, h("input", { type: "checkbox", checked: form.allowUnconfinedLinuxWorkers, onchange: (event) => { form.allowUnconfinedLinuxWorkers = event.target.checked; } }), t("اسمح للعمال بالتعديل لو الكيرنل مفيهوش Landlock", "Let native workers edit projects when this kernel has no Landlock"))
    ),
    h("div", { class: "row" }, h("button", { class: "btn primary", disabled: ui.busy || !team, "data-testid": "save-rules", onclick: () => run("rules", async () => { await invoke("save_rules", { rules: form }); await refresh(); ui.rulesForm = null; toast(t("القواعد محفوظة.", "Rules saved.")); }) }, t("احفظ القواعد", "Save rules"))),
  ];
}

function advisorPage() {
  const consults = ui.activity?.consults ?? [];
  const team = ui.data.state.team;
  return [
    header(t("المستشار", "Advisor"), t("Independent advice, primary decision", "Independent advice, primary decision"), "crew-advisor-v2"),
    h("div", { class: "card" }, h("h2", {}, team?.advisor ? label(team.advisor) : t("مفيش مستشار", "No advisor")), h("p", { class: "muted" }, t("الأساسي بيستشير حسب سياستك من جوّه محادثتك. الاستشارات بتظهر هنا.", "Your primary consults according to your policy, from inside your chat. Consultations appear here."))),
    consults.length
      ? consults.map((record) =>
          h(
            "details",
            { class: "card" },
            h("summary", {}, record.question),
            h("div", { class: "row" }, h("span", { class: "muted small" }, record.provider), h("span", { class: "badge" }, record.decision ?? record.status)),
            record.rounds.map((round) => h("div", { class: "pre" }, round.advice)),
            record.summary && h("p", {}, record.summary)
          )
        )
      : h("p", { class: "muted" }, t("No consultations yet.", "No consultations yet.")),
  ];
}

function assistants() {
  const natives = ui.data.services.filter((item) => item.native).map((item) => item.agent);
  const apis = ui.data.services.filter((item) => !item.native).map((item) => item.agent);
  return [
    header(t("المساعدون والاشتراكات", "Assistants & plans"), t("Your accounts", "Your accounts"), "crew-contractors"),
    h("h2", {}, t("الحسابات الرسمية", "Official accounts")),
    h("div", { class: "row" }, h("button", { class: "btn", disabled: ui.busy, onclick: () => run("prepare", () => prepareServices(natives.filter((agent) => !service(agent).installed))) }, t("جهّز الخدمات الناقصة", "Prepare missing services"))),
    connectionList(natives),
    h("h2", {}, t("مساعدين عبر API أو محليين", "API and local assistants")),
    apis.map((agent) => h("details", { class: "card", open: service(agent).configured }, h("summary", {}, label(agent)), apiForm(agent), service(agent).configured && h("button", { class: "btn danger", style: "align-self:flex-start", onclick: () => run("remove", async () => { await invoke("remove_assistant", { agent }); delete ui.apiForm[agent]; await refresh(); }) }, t("احذف الخدمة ومفتاحها", "Remove service and key")))),
  ];
}

async function loadSkills() {
  try {
    ui.skills = await invoke("skills_list", { scope: ui.skillsScope, directory: ui.skillsScope === "project" ? ui.skillsDir || ui.data.state.projectDirectory : null });
    render();
  } catch (error) {
    report(error);
  }
}

function skillStatus(status) {
  return (
    { absent: [t("مش متثبت", "Not installed"), ""], installed: [t("متثبت", "Installed"), "good"], modified: [t("اتعدّل بعد التثبيت", "Changed since install"), "warn"], incomplete: [t("تثبيت ناقص", "Incomplete install"), "warn"], external: [t("موجود من مصدر تاني", "Already present from elsewhere"), "warn"], global: [t("متثبت لكل المشاريع", "Installed for all projects"), "good"] }[status] || [t("اختار مكان التثبيت", "Choose a destination"), ""]
  );
}

function skillsPage() {
  const directory = ui.skillsScope === "project" ? ui.skillsDir || ui.data.state.projectDirectory : null;
  const canInstall = ui.skillsScope === "allProjects" || directory;
  return [
    header("Skills", t("Project skills, memory and instruction templates, with credit and overlap checks before installation.", "Project skills, memory and instruction templates, with credit and overlap checks before installation."), "crew-skills-v2"),
    h(
      "div",
      { class: "card" },
      h("h3", {}, t("تثبيت في", "Install to")),
      segmented([["project", t("مشروع محدد", "A specific project")], ["allProjects", t("كل المشاريع", "All projects")]], ui.skillsScope, (value) => { ui.skillsScope = value; ui.skills = null; loadSkills(); render(); }),
      ui.skillsScope === "project" && h("div", { class: "row" }, directory ? h("code", { class: "ltr", dir: "ltr" }, directory) : h("span", { class: "muted" }, t("مفيش فولدر متحدد.", "No folder chosen.")), h("button", { class: "btn", disabled: ui.busy, onclick: () => run("folder", async () => { const picked = await invoke("pick_folder"); if (picked) { ui.skillsDir = picked; await loadSkills(); } }) }, t("اختار فولدر", "Choose folder")))
    ),
    !ui.skills && busyRow(t("لحظات…", "Working…")),
    (ui.skills ?? []).map((item) => {
      const [text, kind] = skillStatus(item.status);
      return h(
        "div",
        { class: "card" },
        h("div", { class: "row between" }, h("strong", {}, ui.arabic ? item.nameAR : item.name), h("span", { class: `badge ${kind}` }, text)),
        h("p", {}, ui.arabic ? item.descriptionAR : item.description),
        h("p", { class: "muted small" }, `${t("الكريدت", "Credit")}: ${item.author} · ${item.license} · ${item.stars.toLocaleString("en")} ★ (${item.checked})`),
        item.hasScripts && h("span", { class: "badge warn", style: "align-self:flex-start" }, item.hasHooks ? t("فيها سكربتات وHooks", "Includes scripts and hooks") : t("فيها سكربتات", "Includes scripts")),
        h(
          "div",
          { class: "row" },
          h("button", { class: "btn", onclick: () => openLink(item.sourceUrl) }, t("المصدر", "Source")),
          ["absent", "global", "incomplete"].includes(item.status) && h("button", { class: "btn primary", disabled: ui.busy || !canInstall, "data-testid": `preview-${item.id}`, onclick: () => run("preview", async () => { ui.modal = await invoke("skills_preview", { id: item.id, scope: ui.skillsScope, directory }); }) }, t("راجع وثبّت", "Review and install"))
        )
      );
    }),
  ];
}

function skillModal() {
  const plan = ui.modal;
  return h(
    "div",
    { class: "modal-back" },
    h(
      "div",
      { class: "modal", role: "dialog", "aria-modal": "true" },
      h("h2", {}, plan.name),
      h("p", { class: "muted small" }, `${t("الكريدت", "Credit")}: ${plan.author} · ${plan.license}`),
      h("p", {}, plan.scope === "allProjects" ? t("هيتثبت لكل مشاريعك المحلية.", "This installs for all your local projects.") : h("code", { class: "ltr", dir: "ltr" }, plan.destination)),
      plan.warnings.length > 0 && h("div", { class: "notice" }, plan.warnings.map((warning) => h("p", {}, warning))),
      h("details", {}, h("summary", {}, `${t("الملفات", "Files")} (${plan.writes.length})`), h("div", { class: "pre ltr", dir: "ltr" }, plan.writes.join("\n"))),
      h("details", {}, h("summary", {}, t("معاينة", "Preview")), h("div", { class: "pre ltr", dir: "ltr" }, plan.preview)),
      h("p", { class: "muted small" }, t("تعليماتك الحالية بتفضل زي ما هي، والجديد بيتضاف في قسم منفصل.", "Your existing instructions stay as they are; new text goes in a separate section.")),
      h("div", { class: "row" }, h("button", { class: "btn primary", disabled: ui.busy, "data-testid": "confirm-install", onclick: () => run("install", async () => { await invoke("skills_install", { id: plan.id }); ui.modal = null; await loadSkills(); toast(t("اتثبت.", "Installed.")); }) }, t("ثبّت", "Install")), h("button", { class: "btn", onclick: () => { ui.modal = null; render(); } }, t("إلغاء", "Cancel")))
    )
  );
}

async function loadDaily(force) {
  try {
    ui.daily = await invoke("daily_load", { refresh: force });
    render();
  } catch (error) {
    report(error);
  }
}

function dailyPage() {
  const data = ui.daily;
  const reading = data?.reading ?? { saved: [], read: [] };
  const articles = (data?.snapshot.articles ?? []).filter((article) => ui.dailyFilter === "all" || (ui.dailyFilter === "saved" ? reading.saved.includes(article.url) : article.topic === ui.dailyFilter));
  const topics = { models: t("النماذج والأبحاث", "Models & research"), coding: t("أدوات البرمجة", "Coding tools"), agents: t("الوكلاء والاستخدام العملي", "Agents & practice") };
  return [
    header(t("أخبار المطوّرين", "Developer Daily"), t("Fresh tools and agent news. Original sources, practical next steps.", "Fresh tools and agent news. Original sources, practical next steps."), "crew-daily-v2"),
    h("div", { class: "row between" }, segmented([["all", t("الكل", "All")], ...Object.entries(topics), ["saved", t("المحفوظ", "Saved")]], ui.dailyFilter, (value) => { ui.dailyFilter = value; render(); }), h("button", { class: "btn", disabled: ui.busy, onclick: () => run("daily", () => loadDaily(true)) }, t("حدّث", "Refresh"))),
    data?.snapshot.failures.length > 0 && h("div", { class: "notice" }, t("بعض المصادر مش متاحة دلوقتي.", "Some sources are unavailable right now.")),
    !data && busyRow(t("لحظات…", "Working…")),
    data && articles.length === 0 && h("p", { class: "muted" }, t("No headlines to show", "No headlines to show")),
    articles.map((article) => {
      const saved = reading.saved.includes(article.url);
      return h(
        "div",
        { class: "card" },
        h("strong", { dir: "auto" }, article.title),
        h("p", { class: "muted small" }, `${data.sources[article.sourceId] ?? ""} · ${new Date(article.published).toLocaleDateString(ui.arabic ? "ar-EG" : "en-US")} · ${topics[article.topic]}`),
        h(
          "div",
          { class: "row" },
          h("button", { class: "btn", onclick: () => { openLink(article.url); invoke("daily_mark", { article, read: true }).then((value) => { data.reading = value; render(); }).catch(report); } }, t("اقرأ المصدر", "Read source")),
          h("button", { class: "btn", onclick: () => invoke("daily_mark", { article, saved: !saved }).then((value) => { data.reading = value; render(); }).catch(report) }, saved ? t("Saved for later", "Saved for later") : t("Save for later", "Save for later")),
          h("button", { class: "btn primary", onclick: async () => { const brief = await invoke("daily_brief", { article, arabic: ui.arabic }); toast((await copy(brief)) ? t("Brief copied", "Brief copied") : t("النسخ ما نجحش.", "Could not copy.")); } }, t("Prepare a team task", "Prepare a team task"))
        )
      );
    }),
  ];
}

function tasks() {
  const query = ui.search.toLowerCase();
  const jobs = (ui.activity?.jobs ?? []).filter((job) => !query || `${job.title} ${job.result ?? ""}`.toLowerCase().includes(query));
  return [
    header(t("المهام والمراجعات", "Tasks & reviews"), t("Task results saved in this workshop.", "Task results saved in this workshop."), "crew-worklog"),
    h("input", { type: "search", value: ui.search, placeholder: t("دوّر في المهام", "Search tasks"), "aria-label": t("دوّر في المهام", "Search tasks"), oninput: (event) => { ui.search = event.target.value; render(); document.querySelector('input[type="search"]')?.focus(); } }),
    jobs.length ? jobs.map(jobCard) : h("p", { class: "muted" }, ui.search ? t("No results match this search", "No results match this search") : t("The ledger is empty", "The ledger is empty")),
  ];
}

function usage() {
  const jobs = ui.activity?.jobs ?? [];
  const consults = ui.activity?.consults ?? [];
  const metered = ui.data.services.filter((item) => item.configured);
  return [
    header(t("الاستخدام والحدود", "Usage & limits"), t("Local activity", "Local activity"), "crew-usage"),
    h("div", { class: "grid" }, h("div", { class: "card" }, h("h2", {}, String(jobs.length)), h("p", { class: "muted" }, t("مهام اتفوضت", "Delegated tasks"))), h("div", { class: "card" }, h("h2", {}, String(consults.length)), h("p", { class: "muted" }, t("استشارات", "Consultations")))),
    h(
      "div",
      { class: "card" },
      h("h2", {}, t("طلبات API النهارده", "API requests today")),
      metered.length
        ? metered.map((item) => h("div", { class: "status-line" }, h("strong", {}, item.label), h("span", { dir: "ltr" }, `${item.usage?.requests ?? 0} / ${item.dailyRequestLimit} · ${item.usage?.input ?? 0} in · ${item.usage?.output ?? 0} out`)))
        : h("p", { class: "muted" }, t("مفيش خدمات API متوصلة.", "No API services connected.")),
      h("p", { class: "muted small" }, t("الحد اليومي محلي من التطبيق. رصيد حسابك الرسمي مش ظاهر هنا.", "The daily cap is set locally. Your official account balance is not shown here."))
    ),
  ];
}

function settings() {
  const state = ui.data.state;
  return [
    header(t("الإعدادات", "Settings"), t("Workshop language and storage.", "Workshop language and storage."), "crew-settings"),
    h(
      "div",
      { class: "card" },
      h("h2", {}, t("الشكل واللغة", "Appearance and language")),
      segmented([["system", t("زي النظام", "System")], ["light", t("فاتح", "Light")], ["dark", t("غامق", "Dark")]], state.appearance, async (appearance) => { await invoke("set_preferences", { appearance }); await refresh(); render(); }),
      languageButton()
    ),
    h(
      "div",
      { class: "card" },
      h("h2", {}, t("اللي شغّال على الجهاز ده", "What works on this computer")),
      h("p", { class: "muted small", dir: "ltr" }, `${ui.data.platform.os} · ${ui.data.platform.arch} · ${ui.data.version}`),
      ui.data.capabilities.map((item) =>
        h("div", { class: "status-line", style: "align-items:flex-start" }, h("p", {}, ui.arabic ? item.ar : item.en), h("span", { class: `badge ${item.level === "supported" ? "good" : item.level === "limited" ? "warn" : "bad"}` }, { supported: t("مدعوم", "Supported"), limited: t("محدود", "Limited"), unavailable: t("مش متاح", "Unavailable") }[item.level]))
      )
    ),
    h(
      "div",
      { class: "card" },
      h("h2", {}, t("مجاني ومفتوح المصدر", "Free and open source")),
      h("p", {}, t("نسخة الفواعلي الرسمية مجانية وهتفضل دائمًا مجانية. الرخصة AGPL-3.0-or-later.", "The official app is free and will remain free. Licensed AGPL-3.0-or-later.")),
      h("p", {}, t("الفكرة والاسم الأصلي: أحمد نجدي. التطوير: Daxow والمساهمون.", "Original idea and name: Ahmed Nagdy. Development: Daxow and contributors.")),
      h("div", { class: "row" }, h("button", { class: "btn", onclick: () => openLink("https://nagdy.me/") }, t("أحمد نجدي", "Ahmed Nagdy")), h("button", { class: "btn", onclick: () => openLink("https://github.com/amElnagdy/delegate-skills") }, t("الفكرة الأصلية", "The original idea")), h("button", { class: "btn", onclick: () => openLink("https://github.com/daxowapp/fawaly") }, t("الكود المصدري", "Source code"))),
      h("p", { class: "muted small" }, t("خط لاليزار برخصة SIL OFL. أسماء الخدمات والعلامات لأصحابها.", "Lalezar font under the SIL OFL. Provider names and trademarks belong to their owners."))
    ),
    h(
      "div",
      { class: "card" },
      h("h2", {}, t("الخصوصية والبيانات", "Privacy and data")),
      h("p", { class: "muted" }, t("Keys stay here", "Keys stay here")),
      h("button", { class: "btn danger", style: "align-self:flex-start", disabled: ui.busy, "data-testid": "remove-data", onclick: () => { ui.confirmRemove = true; render(); } }, t("افصل الفريق وامسح بياناتي من الجهاز", "Disconnect the team and remove my data")),
      ui.confirmRemove &&
        h("div", { class: "notice" }, h("p", {}, t("هيتمسح ربط الفريق وسجل المهام ومفاتيحك وتسجيلات الدخول الخاصة بالتطبيق. مشاريعك مش هتتأثر. مش هتقدر ترجع في الخطوة دي.", "This removes the team connection, the task log, your keys and this app's sign-ins. Your projects are not touched. This cannot be undone.")), h("div", { class: "row" }, h("button", { class: "btn danger", "data-testid": "confirm-remove", onclick: () => run("remove", async () => { await invoke("remove_my_data"); ui.confirmRemove = false; await refresh(); ui.step = 0; ui.draft = null; toast(t("اتمسحت.", "Removed.")); }) }, t("امسح نهائيًا", "Remove permanently")), h("button", { class: "btn", onclick: () => { ui.confirmRemove = false; render(); } }, t("إلغاء", "Cancel"))))
    ),
  ];
}

/* ---------- Root ---------- */

function render() {
  if (!ui.data) return;
  const root = document.getElementById("app");
  const active = document.activeElement;
  const focusId = active?.dataset?.testid;
  const onboardingNeeded = ui.data.state.onboardingVersion == null || ui.page === "edit";
  let content;
  if (onboardingNeeded) {
    content = onboarding();
  } else {
    const views = { home, connection, rules, advisor: advisorPage, assistants, skills: skillsPage, daily: dailyPage, tasks, usage, settings };
    content = h(
      "div",
      { class: "shell" },
      h("div", { class: "topbar" }, h("span", { class: "brand-mark" }, icon("hammer")), h("span", { class: "brand" }, ui.arabic ? "الفواعلي" : "Sudo Interns"), h("span", { class: "spacer" }), languageButton()),
      h("div", { class: "stripe", "aria-hidden": "true" }),
      h(
        "div",
        { class: "body" },
        h(
          "nav",
          { class: "sidebar", "aria-label": t("الأقسام", "Sections") },
          PAGES().map(([id, iconName, title, child]) => h("button", { class: `nav ${child ? "child" : ""} ${ui.page === id ? "active" : ""}`, "aria-current": ui.page === id ? "page" : undefined, "data-testid": `nav-${id}`, onclick: () => goto(id) }, !child && icon(iconName), h("span", {}, title))),
          h("div", { class: "sidebar-note" }, h("strong", {}, ui.arabic ? "القهوة علينا. الشغل عليهم." : "Overprompted. Underpaid."), h("p", { class: "muted small" }, t("Keys stay here", "Keys stay here")))
        ),
        h("main", {}, h("div", { class: "page" }, views[ui.page]()))
      )
    );
  }
  root.replaceChildren(content, ...(ui.modal ? [skillModal()] : []));
  if (focusId) document.querySelector(`[data-testid="${focusId}"]`)?.focus();
}

// A rendering bug must never leave a silent blank window.
function showFatal(detail) {
  const root = document.getElementById("app");
  if (!root.firstChild) root.textContent = `Sudo Interns could not open this screen: ${detail}`;
}
window.addEventListener("error", (event) => showFatal(event.message));
window.addEventListener("unhandledrejection", (event) => showFatal(event.reason));

async function start() {
  try {
    await refresh();
  } catch (error) {
    document.getElementById("app").textContent = String(error);
    return;
  }
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => theme(ui.data.state.appearance));
  await listen("signin-url", (event) => {
    ui.browserUrl = event.payload;
    render();
  });
  ui.mode = "important";
  if (ui.data.state.team) ui.draft = structuredClone(ui.data.state.team);
  if (ui.data.state.onboardingVersion != null) goto("home");
  else render();
  if (ui.data.selftest) {
    const report = () => invoke("selftest_report", { text: document.body.innerText, dir: document.documentElement.dir });
    await report();
    await setArabic(!ui.arabic);
    await report();
  }
}

start();
