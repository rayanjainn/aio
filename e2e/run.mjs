// End-to-end UI tests: boots the Vite dev server, opens every Cortex surface
// (palette, settings, studio, all widget kinds, dock, island) in Chromium with
// the Tauri bridge mocked (e2e/mock.js), and checks behaviour + console errors.
//
//   npm run test:e2e            # headless; screenshots in e2e/screenshots/
//
// Needs Playwright's Chromium on the machine (`npx playwright install chromium`).
import { createServer } from "vite";
import { createRequire } from "node:module";
import { readFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const here = dirname(fileURLToPath(import.meta.url));
const MOCK = readFileSync(join(here, "mock.js"), "utf8");
const SHOTS = join(here, "screenshots");
mkdirSync(SHOTS, { recursive: true });

const WIDGET_KINDS = ["clock", "calendar", "weather", "music", "photo", "search", "app", "tabs", "running", "projects", "recent",
  "downloads", "shell", "notes", "todos", "focus", "countdown", "launcher", "clipboard", "system", "battery", "coding", "git", "docker", "github"];

const server = await createServer({ root: join(here, ".."), logLevel: "error", server: { port: 5199, strictPort: false } });
await server.listen();
const BASE = server.resolvedUrls.local[0].replace(/\/$/, "");
const browser = await chromium.launch();

let passed = 0, failed = 0;
const results = [];

/** New page with the mock (and optional fixture script) injected. */
async function open(path, { w = 880, h = 540, pre = "" } = {}) {
  const page = await browser.newPage({ viewport: { width: w, height: h } });
  page.errors = [];
  page.on("pageerror", e => page.errors.push(e.message));
  page.on("console", m => { if (m.type() === "error") page.errors.push(m.text()); });
  await page.addInitScript({ content: pre + "\n" + MOCK });
  await page.goto(BASE + path);
  await page.waitForTimeout(500);
  return page;
}

function assert(cond, msg) { if (!cond) throw new Error(msg); }

async function test(name, fn) {
  const t0 = Date.now();
  try {
    await fn();
    passed++; results.push(`  ✓ ${name} (${Date.now() - t0}ms)`);
  } catch (e) {
    failed++; results.push(`  ✗ ${name}\n      ${String(e.message || e).split("\n")[0]}`);
  }
}

async function noErrors(page) {
  assert(page.errors.length === 0, `console errors: ${page.errors.join(" | ")}`);
}

/* ── Palette ──────────────────────────────────────────── */

await test("palette renders running apps and commands", async () => {
  const p = await open("/");
  await p.waitForSelector("text=Running");
  await p.waitForSelector("text=Widgets & Dock");
  await noErrors(p); await p.close();
});

await test("calculator and unit conversion", async () => {
  const p = await open("/");
  await p.click("input");
  await p.keyboard.type("12*7");
  await p.waitForSelector("text=84");
  await noErrors(p); await p.close();
});

await test("emoji picker via ':' prefix", async () => {
  const p = await open("/");
  await p.click("input");
  await p.keyboard.type(":fire");
  await p.waitForSelector("text=Emoji");
  await p.close();
});

await test("window command snaps via Accessibility API", async () => {
  const p = await open("/");
  await p.click("input");
  await p.keyboard.type("left half");
  await p.waitForSelector("text=Window: Left Half");
  await p.click("text=Window: Left Half");
  await p.waitForFunction(() => window.__LAST_SNAP__ === "left", null, { timeout: 2000 });
  await p.close();
});

await test("focus timer command emits island-timer", async () => {
  const p = await open("/");
  await p.click("input");
  await p.keyboard.type("start focus");
  await p.click("text=Start Focus Timer");
  await p.waitForFunction(() => window.__CALLS__.some(([c, a]) => c === "plugin:event|emit" && a.event === "island-timer"), null, { timeout: 2000 });
  await p.close();
});

/* ── Settings → Shortcuts ─────────────────────────────── */

await test("shortcut recorder rebinds and reports conflicts", async () => {
  const p = await open("/", { w: 820, h: 600 });
  await p.click("button[title^=Settings]");
  await p.click("text=Shortcuts");
  await p.waitForSelector("[data-testid=sc-palette]");
  await p.click("[data-testid=sc-palette] .sc-btn");
  await p.waitForSelector("text=Press keys");
  await p.keyboard.press("Alt+Space");
  await p.waitForFunction(() => window.__LAST_SHORTCUT__?.accel === "Alt+Space", null, { timeout: 2000 });
  // Conflict: give "island" the same combo → error shown, not saved.
  await p.click("[data-testid=sc-island] .sc-btn");
  await p.keyboard.press("Alt+Space");
  await p.waitForSelector("text=Already used for");
  await p.screenshot({ path: join(SHOTS, "settings-shortcuts.png") });
  await noErrors(p); await p.close();
});

await test("settings is opaque over the palette (no see-through)", async () => {
  const p = await open("/", { w: 820, h: 600 });
  await p.click("button[title^=Settings]");
  await p.waitForSelector("text=General");
  const paletteVisible = await p.$("input[placeholder^='Search apps']");
  assert(!paletteVisible, "palette still rendered under Settings");
  await p.close();
});

await test("about shows version and automatic updates", async () => {
  const p = await open("/", { w: 820, h: 600 });
  await p.click("button[title^=Settings]");
  await p.click("text=About");
  await p.waitForSelector("text=Cortex 0.2.0");
  await p.waitForSelector("text=Install updates automatically");
  await p.click("text=Check Now");
  await p.waitForFunction(() => window.__CALLS__.some(([c, a]) => c === "update_check" && a.install === true), null, { timeout: 2000 });
  await noErrors(p); await p.close();
});

/* ── Studio ───────────────────────────────────────────── */

await test("studio gallery lists every widget and adds one", async () => {
  const p = await open("/", { w: 1080, h: 720 });
  await p.click("text=Widgets & Dock");
  await p.waitForSelector("text=Gallery");
  const cards = await p.$$(".gallery-card");
  assert(cards.length >= WIDGET_KINDS.length, `expected ≥${WIDGET_KINDS.length} gallery cards, got ${cards.length}`);
  await p.click(".gallery-card >> text=Add");
  await p.waitForFunction(() => window.__CALLS__.some(([c]) => c === "widget_add"), null, { timeout: 2000 });
  for (const tab of ["Cortex Dock", "macOS Dock", "Island"]) {
    await p.click(`.segmented >> text=${tab}`);
    await p.waitForTimeout(250);
  }
  await p.screenshot({ path: join(SHOTS, "studio-island.png") });
  await noErrors(p); await p.close();
});

/* ── Every widget kind, every size ────────────────────── */

await test(`all ${WIDGET_KINDS.length} widget kinds render at S/M/L without errors`, async () => {
  const sizes = { s: [170, 170], m: [360, 170], l: [360, 380] };
  const ws = [];
  for (const k of WIDGET_KINDS) for (const [sz, [w, h]] of Object.entries(sizes)) {
    ws.push({ id: `${k}-${sz}`, kind: k, x: 0, y: 0, w, h, layer: "desktop", locked: false,
      config: k === "app" ? { app: { name: "Spotify", path: "/Applications/Spotify.app" } } : k === "weather" ? { city: "Pune" } : k === "countdown" ? { date: "2030-01-01" } : {} });
  }
  const pre = `window.__MOCK_WIDGETS__ = ${JSON.stringify(ws)};`;
  const bad = [];
  for (const w of ws) {
    const p = await open(`/#/widget/${w.id}`, { w: w.w, h: w.h, pre });
    await p.waitForSelector(".w-card", { timeout: 3000 }).catch(() => bad.push(`${w.id}: no card`));
    const crashed = await p.$("text=Something went wrong");
    if (crashed) bad.push(`${w.id}: crashed`);
    if (p.errors.length) bad.push(`${w.id}: ${p.errors[0]}`);
    if (w.id.endsWith("-m") && ["music", "coding", "app", "system"].includes(w.kind)) {
      await p.waitForTimeout(600);
      await p.screenshot({ path: join(SHOTS, `widget-${w.id}.png`) });
    }
    await p.close();
  }
  assert(bad.length === 0, bad.join("; "));
});

/* ── Dock ─────────────────────────────────────────────── */

await test("dock: magnifies under the pointer and launches on one click", async () => {
  const pre = `window.__MOCK_DOCK__ = { enabled: true, edge: "bottom", iconSize: 52, magnify: true, autohide: false, showRunning: true, hideSystemDock: false,
    items: [{type:"app",name:"Finder",path:"/System/Library/CoreServices/Finder.app"},{type:"app",name:"Safari",path:"/Applications/Safari.app"},{type:"separator"},{type:"widget",kind:"music"},{type:"widget",kind:"coding"},{type:"widget",kind:"timer"},{type:"widget",kind:"clock"}] };`;
  const p = await open("/#/dock", { w: 900, h: 160, pre });
  await p.waitForSelector(".dk-tile");
  await p.waitForTimeout(700); // let mini widgets load so the bar stops resizing
  const tile = await p.$$(".dk-tile");
  const box = await tile[1].boundingBox();
  await p.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await p.waitForTimeout(250);
  const scale = await tile[1].evaluate(el => el.style.transform);
  assert(/scale\(1\.[3-9]/.test(scale), `hovered icon not magnified (${scale})`);
  await p.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  await p.waitForTimeout(200);
  const launches = await p.evaluate(() => window.__CALLS__.filter(([c]) => c === "launch_path").length);
  assert(launches === 1, `expected 1 launch from a single click, got ${launches}`);
  await p.screenshot({ path: join(SHOTS, "dock.png") });
  await noErrors(p); await p.close();
});

/* ── Island ───────────────────────────────────────────── */

await test("island: compact activity, hover expands, toast and timer", async () => {
  const p = await open("/#/island", { w: 760, h: 320 });
  await p.waitForSelector(".is-pill");
  const w0 = await p.$eval(".is-pill", el => el.getBoundingClientRect().width);
  assert(w0 > 186 && w0 < 420, `compact width ${w0}`);
  await p.evaluate(() => window.__emit("island-hover", true));
  await p.waitForTimeout(700);
  const w1 = await p.$eval(".is-pill", el => el.getBoundingClientRect().width);
  assert(w1 >= 590, `expanded width ${w1}`);
  await p.waitForSelector("text=Coding today");
  await p.screenshot({ path: join(SHOTS, "island-expanded.png") });
  await p.evaluate(() => window.__emit("island-hover", false));
  await p.evaluate(() => window.__emit("island-toast", { icon: "copy", text: "Copied" }));
  await p.waitForSelector(".is-compact >> text=Copied");
  await p.evaluate(() => window.__emit("island-timer", { minutes: 25 }));
  await p.waitForTimeout(2500); // toast clears, timer takes over
  await p.waitForSelector(".is-compact >> text=Focus");
  const pillReports = await p.evaluate(() => window.__CALLS__.filter(([c]) => c === "island_pill").length);
  assert(pillReports > 0, "pill rect never reported to backend");
  await noErrors(p); await p.close();
});

await test("island: hidden when idle on a screen without a notch", async () => {
  const pre = `window.__MOCK__ = { handlers: {
    island_geometry: () => ({ hasNotch: false, notchWidth: 0, menuBarHeight: 24, windowWidth: 760 }),
    now_playing: () => ({ app: "", state: "stopped" }),
    coding_usage: () => ({ claude: { active: false, todayTokens: 0, week: [] }, codex: { active: false, todayTokens: 0, week: [] } }),
    calendar_upcoming: () => [] } };`;
  const p = await open("/#/island", { w: 760, h: 320, pre });
  await p.waitForSelector(".is-pill", { state: "attached" });
  await p.waitForTimeout(700);
  const { op, w } = await p.$eval(".is-pill", el => ({ op: getComputedStyle(el).opacity, w: el.getBoundingClientRect().width }));
  assert(op === "0" || w === 0, `idle pill visible (opacity ${op}, width ${w})`);
  // An activity brings it back.
  await p.evaluate(() => window.__emit("island-toast", { icon: "check", text: "Saved" }));
  await p.waitForSelector(".is-compact >> text=Saved");
  await p.close();
});

await browser.close();
await server.close();
console.log(results.join("\n"));
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
