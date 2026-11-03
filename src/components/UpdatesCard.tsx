/** Settings → About: version, automatic updates, check / restart. */
import { useEffect, useState } from "react";
import { invoke } from "../lib/tauri";

interface Status { current: string; available: string | null; ready: string | null; notes: string | null; error: string | null }

export default function UpdatesCard() {
  const [s, setS] = useState<Status | null>(null);
  const [busy, setBusy] = useState(false);
  const [auto, setAuto] = useState(true);
  useEffect(() => {
    invoke<Status>("update_check", { install: false }).then(setS).catch(() => {});
    invoke<{ ui?: { autoUpdate?: boolean } }>("get_config").then(c => setAuto(c?.ui?.autoUpdate !== false)).catch(() => {});
    let off: (() => void) | undefined;
    import("@tauri-apps/api/event").then(({ listen }) => listen<string>("update-ready", e => setS(x => x && { ...x, ready: e.payload })))
      .then(u => { off = u; }).catch(() => {});
    return () => off?.();
  }, []);
  const check = async () => {
    setBusy(true);
    try { setS(await invoke<Status>("update_check", { install: true })); } finally { setBusy(false); }
  };
  const msg = !s ? "Checking…"
    : s.ready ? `Cortex ${s.ready} is installed — restart to finish`
    : s.error ? `Couldn't check: ${s.error}`
    : s.available ? `Cortex ${s.available} is available`
    : "You're up to date";
  return (
    <div className="glass" style={{ padding: "14px 18px", borderRadius: 14, display: "flex", flexDirection: "column", gap: 12 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 13.5, fontWeight: 600 }}>Cortex {s?.current ?? ""}</div>
          <div style={{ fontSize: 12, color: "rgba(255,255,255,0.5)" }}>{msg}</div>
        </div>
        {s?.ready
          ? <button className="btn-glass btn-accent" onClick={() => invoke("update_restart")}>Restart to Update</button>
          : <button className="btn-glass" disabled={busy} onClick={check}>{busy ? "Checking…" : s?.available ? "Install" : "Check Now"}</button>}
      </div>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <span style={{ fontSize: 12.5, color: "rgba(255,255,255,0.6)" }}>Install updates automatically</span>
        <button className="toggle" data-on={auto} onClick={() => { const v = !auto; setAuto(v); invoke("set_ui_value", { key: "autoUpdate", value: v }).catch(() => {}); }}><span /></button>
      </div>
    </div>
  );
}
