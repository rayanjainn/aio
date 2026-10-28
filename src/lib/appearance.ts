/**
 * Appearance — glass density and motion (one fixed, subtle accent). Persisted in the
 * backend config (`ui.appearance`) so every Cortex window (palette, desktop
 * widgets, dock) shares it; changes are broadcast with `appearance-changed`.
 */
import { IN_TAURI, invoke } from "./tauri";

export type Tint = "clear" | "regular" | "frosted";
export interface Appearance {
  tint: Tint;
  motion: "full" | "reduced";
}

// Over Apple's native Liquid Glass the material already does the work, so the
// CSS tint is a whisper; over plain vibrancy it carries more of the look.
const TINT_ALPHA: Record<"native" | "vibrancy", Record<Tint, number>> = {
  native:   { clear: 0.0,  regular: 0.08, frosted: 0.26 },
  vibrancy: { clear: 0.14, regular: 0.30, frosted: 0.52 },
};
let nativeGlass = false;

export const DEFAULT_APPEARANCE: Appearance = { tint: "regular", motion: "full" };

export function applyAppearance(a: Appearance): void {
  const root = document.documentElement;
  const alpha = TINT_ALPHA[nativeGlass ? "native" : "vibrancy"][a.tint] ?? 0.2;
  // Precomputed colours: Safari/WKWebView rejects calc() inside rgba(), which
  // made overlays (Settings) fully transparent.
  root.style.setProperty("--tint-alpha", String(alpha));
  root.style.setProperty("--glass-tint", `rgba(var(--tint-rgb),${alpha})`);
  root.style.setProperty("--glass-tint-strong", `rgba(var(--tint-rgb),${Math.min(0.9, alpha + (nativeGlass ? 0.2 : 0.32))})`);
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
  if (IN_TAURI) {
    try { nativeGlass = !!(await invoke<{ native: boolean }>("glass_info")).native; } catch { /* older backend */ }
  }
  document.documentElement.classList.toggle("native-glass", nativeGlass);
  applyAppearance(await loadAppearance());
  if (!IN_TAURI) return;
  const { listen } = await import("@tauri-apps/api/event");
  await listen<Appearance>("appearance-changed", e => applyAppearance(e.payload));
}
