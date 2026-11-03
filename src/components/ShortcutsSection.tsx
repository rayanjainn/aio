/**
 * Settings → Shortcuts: every global hotkey, re-bindable. Click a shortcut,
 * press the new combination (Esc cancels, ⌫ clears). Hotkeys are suspended
 * while recording so pressing ⌘K here doesn't open the palette.
 */
import { useEffect, useState } from "react";
import { invoke } from "../lib/tauri";

interface Entry { id: string; label: string; group: string; accel: string; default: string; error: string | null }

const SYM: Record<string, string> = {
  CommandOrControl: "⌘", Command: "⌘", Super: "⌘", Cmd: "⌘", Control: "⌃", Ctrl: "⌃", Alt: "⌥", Option: "⌥", Shift: "⇧",
  ArrowLeft: "←", ArrowRight: "→", ArrowUp: "↑", ArrowDown: "↓", Enter: "↩", Backspace: "⌫", Space: "Space", Escape: "Esc", Tab: "⇥",
  Minus: "-", Equal: "=", BracketLeft: "[", BracketRight: "]", Comma: ",", Period: ".", Slash: "/", Semicolon: ";", Quote: "'", Backquote: "`", Backslash: "\\",
};

/** "Control+Alt+ArrowLeft" → ["⌃", "⌥", "←"] in macOS modifier order. */
export function prettyAccel(accel: string): string[] {
  if (!accel) return [];
  const parts = accel.split("+");
  const order = ["Control", "Ctrl", "Alt", "Option", "Shift", "CommandOrControl", "Command", "Super", "Cmd"];
  const mods = parts.filter(p => order.includes(p)).sort((a, b) => order.indexOf(a) - order.indexOf(b));
  const key = parts.filter(p => !order.includes(p)).map(k => SYM[k] ?? k.replace(/^Key/, "").replace(/^Digit/, ""));
  return [...mods.map(m => SYM[m]), ...key];
}

/** KeyboardEvent → accelerator string, or null while only modifiers are down. */
export function accelFromEvent(e: { metaKey: boolean; ctrlKey: boolean; altKey: boolean; shiftKey: boolean; code: string }): string | null {
  const code = e.code;
  if (/^(Meta|Control|Alt|Shift|OS)(Left|Right)?$/.test(code)) return null;
  const mods = [e.ctrlKey && "Control", e.altKey && "Alt", e.shiftKey && "Shift", e.metaKey && "CommandOrControl"].filter(Boolean) as string[];
  const fn = /^F\d{1,2}$/.test(code);
  if (!mods.length && !fn) return null; // plain letters would hijack typing everywhere
  return [...mods, code].join("+");
}

function Keys({ accel, dim }: { accel: string; dim?: boolean }) {
  const ks = prettyAccel(accel);
  if (!ks.length) return <span style={{ fontSize: 12, color: "rgba(255,255,255,0.3)" }}>Off</span>;
  return (
    <span style={{ display: "inline-flex", gap: 4, opacity: dim ? 0.5 : 1 }}>
      {ks.map((k, i) => <kbd key={i} className="sc-key">{k}</kbd>)}
    </span>
  );
}

export default function ShortcutsSection() {
  const [list, setList] = useState<Entry[]>([]);
  const [rec, setRec] = useState<string | null>(null);
  const [err, setErr] = useState<{ id: string; msg: string } | null>(null);
  const [ax, setAx] = useState<boolean | null>(null);

  useEffect(() => {
    invoke<Entry[]>("shortcuts_get").then(setList).catch(() => {});
    invoke<boolean>("accessibility_status").then(setAx).catch(() => {});
  }, []);

  useEffect(() => {
    if (!rec) return;
    invoke("shortcuts_suspend", { suspend: true }).catch(() => {});
    const onKey = async (e: KeyboardEvent) => {
      e.preventDefault(); e.stopPropagation();
      if (e.code === "Escape") { setRec(null); return; }
      const accel = (e.code === "Backspace" || e.code === "Delete") && !e.metaKey && !e.ctrlKey && !e.altKey ? "" : accelFromEvent(e);
      if (accel === null) return;
      try {
        setList(await invoke<Entry[]>("shortcut_set", { id: rec, accel }));
        setErr(null);
      } catch (x) {
        setErr({ id: rec, msg: typeof x === "string" ? x : "Couldn't set that shortcut" });
      }
      setRec(null);
    };
    window.addEventListener("keydown", onKey, true);
    return () => { window.removeEventListener("keydown", onKey, true); invoke("shortcuts_suspend", { suspend: false }).catch(() => {}); };
  }, [rec]);

  const groups = Array.from(new Set(list.map(l => l.group)));
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 18 }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <h2 className="display" style={{ fontSize: 17, margin: 0 }}>Shortcuts</h2>
        <button className="btn-glass" onClick={() => invoke<Entry[]>("shortcut_reset_all").then(setList).catch(() => {})}>Reset all</button>
      </div>
      {ax === false && (
        <div className="glass" style={{ padding: "12px 16px", borderRadius: 14, fontSize: 12.5, display: "flex", gap: 12, alignItems: "center" }}>
          <span style={{ flex: 1, color: "rgba(255,255,255,0.75)" }}>Window shortcuts need Accessibility access to move other apps' windows.</span>
          <button className="btn-glass btn-accent" onClick={() => invoke<boolean>("accessibility_status", { prompt: true }).then(setAx)}>Allow…</button>
        </div>
      )}
      {groups.map(g => (
        <div key={g} className="glass" style={{ padding: "6px 0", borderRadius: 16 }}>
          <div className="eyebrow" style={{ padding: "8px 16px 4px" }}>{g}</div>
          {list.filter(l => l.group === g).map(l => (
            <div key={l.id} className="sc-row" data-testid={`sc-${l.id}`}>
              <span style={{ flex: 1, fontSize: 13, color: "rgba(255,255,255,0.85)" }}>
                {l.label}
                {(err?.id === l.id || l.error) && <span style={{ display: "block", fontSize: 11, color: "rgba(255,255,255,0.45)" }}>{err?.id === l.id ? err.msg : l.error}</span>}
              </span>
              <button className={`sc-btn${rec === l.id ? " rec" : ""}`} onClick={() => { setErr(null); setRec(rec === l.id ? null : l.id); }}>
                {rec === l.id ? <span className="sc-listen">Press keys… <small>esc cancels · ⌫ clears</small></span> : <Keys accel={l.accel} />}
              </button>
              {l.accel !== l.default && rec !== l.id && (
                <button className="sc-reset" title="Restore default" onClick={() => invoke<Entry[]>("shortcut_set", { id: l.id, accel: l.default }).then(setList).catch(() => {})}>↺</button>
              )}
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}
