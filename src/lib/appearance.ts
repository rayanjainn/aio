/**
 * Appearance — accent colour, glass density and motion. Persisted in the
 * backend config (`ui.appearance`) so every Cortex window (palette, desktop
 * widgets, dock) shares it; changes are broadcast with `appearance-changed`.
 */
import { IN_TAURI, invoke } from "./tauri";

export type Tint = "clear" | "regular" | "frosted";
export interface Appearance {
  accent: string;           // key of ACCENTS
  tint: Tint;
  motion: "full" | "reduced";
}

export const ACCENTS: Record<string, { label: string; rgb: string }> = {
  amber:    { label: "Amber",    rgb: "232,164,48" },
  ocean:    { label: "Ocean",    rgb: "90,170,255" },
  violet:   { label: "Violet",   rgb: "170,130,255" },
  mint:     { label: "Mint",     rgb: "90,225,170" },
  rose:     { label: "Rose",     rgb: "255,120,160" },
  graphite: { label: "Graphite", rgb: "200,200,210" },
};

const TINT_ALPHA: Record<Tint, number> = { clear: 0.22, regular: 0.42, frosted: 0.66 };

export const DEFAULT_APPEARANCE: Appearance = { accent: "amber", tint: "regular", motion: "full" };

export function applyAppearance(a: Appearance): void {
  const root = document.documentElement;
  root.style.setProperty("--accent-rgb", (ACCENTS[a.accent] ?? ACCENTS.amber).rgb);
  root.style.setProperty("--tint-alpha", String(TINT_ALPHA[a.tint] ?? TINT_ALPHA.regular));
  const reduced = a.motion === "reduced" ||
    (typeof matchMedia !== "undefined" && matchMedia("(prefers-reduced-motion: reduce)").matches);
  root.dataset.motion = reduced ? "reduced" : "full";
}

export async function loadAppearance(): Promise<Appearance> {
  if (!IN_TAURI) return readLocal();
  try {
    const cfg = await invoke<{ ui?: { appearance?: Partial<Appearance> } }>("get_config");
    return { ...DEFAULT_APPEARANCE, ...(cfg.ui?.appearance ?? {}) };
  } catch {
    return DEFAULT_APPEARANCE;
  }
}

export async function saveAppearance(a: Appearance): Promise<void> {
  applyAppearance(a);
  if (!IN_TAURI) { try { localStorage.setItem("cortex.appearance", JSON.stringify(a)); } catch { /* private mode */ } return; }
  await invoke("set_ui_value", { key: "appearance", value: a });
  const { emit } = await import("@tauri-apps/api/event");
  await emit("appearance-changed", a);
}

function readLocal(): Appearance {
  try { return { ...DEFAULT_APPEARANCE, ...JSON.parse(localStorage.getItem("cortex.appearance") ?? "{}") }; }
  catch { return DEFAULT_APPEARANCE; }
}

/** Load + apply once, then follow changes made in any window. */
export async function initAppearance(): Promise<void> {
  document.documentElement.classList.toggle("web", !IN_TAURI);
  applyAppearance(await loadAppearance());
  if (!IN_TAURI) return;
  const { listen } = await import("@tauri-apps/api/event");
  await listen<Appearance>("appearance-changed", e => applyAppearance(e.payload));
}
