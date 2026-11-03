/** Studio → Island: turn the Island on/off, pick its style and activities. */
import { useEffect, useState } from "react";
import { motion } from "framer-motion";
import { invoke } from "../lib/tauri";

interface Cfg { enabled: boolean; style: string; music: boolean; coding: boolean; calendar: boolean; battery: boolean; timer: boolean; toasts: boolean; hoverExpand: boolean }

function Row({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 14, padding: "10px 0" }}>
      <div>
        <div style={{ fontSize: 13, color: "rgba(255,255,255,0.85)" }}>{label}</div>
        {hint && <div style={{ fontSize: 11.5, color: "rgba(255,255,255,0.4)", marginTop: 1 }}>{hint}</div>}
      </div>
      {children}
    </div>
  );
}

export default function IslandTab() {
  const [c, setC] = useState<Cfg | null>(null);
  useEffect(() => { invoke<Cfg>("island_get_config").then(setC).catch(() => {}); }, []);
  if (!c) return <div className="skeleton" style={{ height: 200 }} />;
  const save = (p: Partial<Cfg>) => { const n = { ...c, ...p }; setC(n); invoke("island_set_config", { cfg: n }).catch(() => {}); };
  const T = ({ k }: { k: keyof Cfg }) => <button className="toggle" data-on={!!c[k]} onClick={() => save({ [k]: !c[k] } as Partial<Cfg>)}><span /></button>;
  return (
    <div style={{ display: "grid", gridTemplateColumns: "minmax(0,1fr) minmax(0,1fr)", gap: 14, height: "100%", minHeight: 0 }}>
      <div className="glass" style={{ padding: "6px 18px", borderRadius: 18, overflowY: "auto" }}>
        <Row label="Island" hint="A live Dynamic Island around the notch (or in the menu bar)"><T k="enabled" /></Row>
        <Row label="Style">
          <div className="segmented glass-well">
            {[["notch", "Notch black"], ["glass", "Liquid Glass"]].map(([v, l]) => (
              <button key={v} data-active={c.style === v} onClick={() => save({ style: v })}>
                {c.style === v && <motion.span layoutId="is-style" className="liquid-pill" />}{l}
              </button>
            ))}
          </div>
        </Row>
        <Row label="Expand on hover" hint="Off: click the Island to expand"><T k="hoverExpand" /></Row>
        <Row label="Toasts" hint="Copied, window snapped, capture paused…"><T k="toasts" /></Row>
      </div>
      <div className="glass" style={{ padding: "6px 18px", borderRadius: 18, overflowY: "auto" }}>
        <div className="eyebrow" style={{ padding: "10px 0 2px" }}>Live activities</div>
        <Row label="Now playing" hint="Spotify & Music, with controls"><T k="music" /></Row>
        <Row label="Coding" hint="Claude Code & Codex — tokens today, 5-hour block, live “working” state"><T k="coding" /></Row>
        <Row label="Focus timer" hint="Start from ⌘K → Start Focus Timer, or tap in the Island"><T k="timer" /></Row>
        <Row label="Meetings" hint="Shows up 10 minutes before an event"><T k="calendar" /></Row>
        <Row label="Charging" hint="Flashes when you plug in"><T k="battery" /></Row>
      </div>
    </div>
  );
}
