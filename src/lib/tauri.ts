/**
 * Tauri v2 IPC bridge.
 *
 * IMPORTANT: Tauri v2 does NOT inject `window.__TAURI__` unless
 * `app.withGlobalTauri = true`. The reliable runtime marker is
 * `window.__TAURI_INTERNALS__`, which is always present inside the webview.
 * Using `__TAURI__` (v1 behaviour) made every invoke silently no-op —
 * the cause of "no data / 0 indexed" in the UI.
 */

export const IN_TAURI =
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

export async function invoke<T>(
  cmd: string,
  args?: Record<string, unknown>,
): Promise<T> {
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<T>(cmd, args);
}

/**
 * Open an external URL / deeplink. Routes through the Rust `open_url`
 * command (opener crate) so arbitrary schemes work — including macOS
 * System-Settings deeplinks like `x-apple.systempreferences:...` that the
 * shell plugin's URL scope rejects.
 */
export async function openExternal(url: string): Promise<void> {
  if (!IN_TAURI) { window.open(url, "_blank"); return; }
  // Opening an external app blurs Cortex — suppress click-away-hide so the
  // window survives. It re-arms when Cortex regains focus (see App.tsx).
  await invoke("set_autohide", { enabled: false }).catch(() => {});
  await invoke("open_url", { url });
}

/** Resize the main window (logical px) and re-center it. */
export async function resizeWindow(w: number, h: number): Promise<void> {
  if (!IN_TAURI) return;
  const { getCurrentWindow, LogicalSize } = await import("@tauri-apps/api/window");
  const win = getCurrentWindow();
  await win.setSize(new LogicalSize(w, h));
  await win.center();
}

/** Hide the main window (Esc / click-away). */
export async function hideWindow(): Promise<void> {
  if (!IN_TAURI) return;
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  await getCurrentWindow().hide();
}
