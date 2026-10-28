/**
 * Studio tabs for the Cortex Dock and the macOS Dock.
 */
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { motion, Reorder } from "framer-motion";
import { invoke, IN_TAURI } from "../lib/tauri";
import { AppIcon } from "./icons";
import { DOCK_WIDGETS, type DockConfig, type DockItem } from "../dock/types";

type App = { name: string; path: string };

function Row({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) {
  return (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 14, padding: "9px 0" }}>
      <div>
        <div style={{ fontSize: 13, color: "rgba(255,255,255,0.85)" }}>{label}</div>
        {hint && <div style={{ fontSize: 11.5, color: "rgba(255,255,255,0.4)", marginTop: 1 }}>{hint}</div>}
      </div>
      {children}
    </div>
  );
}

function Toggle({ on, set }: { on: boolean; set: (v: boolean) => void }) {
  return <button className="toggle" data-on={on} onClick={() => set(!on)}><span /></button>;
}

function Seg<T extends string>({ id, value, options, set }: { id: string; value: T; options: { v: T; l: string }[]; set: (v: T) => void }) {
  return (
    <div className="segmented glass-well">
      {options.map(o => (
        <button key={o.v} data-active={o.v === value} onClick={() => set(o.v)}>
          {o.v === value && <motion.span layoutId={`seg-${id}`} className="liquid-pill" transition={{ type: "spring", stiffness: 500, damping: 36 }} />}{o.l}
        </button>
      ))}
    </div>
  );
}

function Slider({ value, min, max, step = 1, set, fmt }: { value: number; min: number; max: number; step?: number; set: (v: number) => void; fmt?: (v: number) => string }) {
  const [v, setV] = useState(value);
  useEffect(() => setV(value), [value]);
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 10, width: 220 }}>
      <input type="range" className="slider-glass" min={min} max={max} step={step} value={v}
        style={{ ["--fill" as string]: `${((v - min) / (max - min)) * 100}%` }}
        onChange={e => setV(+e.target.value)} onMouseUp={() => set(v)} onKeyUp={() => set(v)} />
      <span className="tnum mono" style={{ fontSize: 11.5, opacity: 0.6, width: 38, textAlign: "right" }}>{fmt ? fmt(v) : v}</span>
    </div>
  );
}

function AppPicker({ onPick, onClose }: { onPick: (a: App) => void; onClose: () => void }) {
  const [apps, setApps] = useState<App[]>([]);
  const [q, setQ] = useState("");
  useEffect(() => { invoke<App[]>("list_installed_apps").then(setApps).catch(() => {}); }, []);
  const list = apps.filter(a => !q || a.name.toLowerCase().includes(q.toLowerCase())).slice(0, 60);
  return (
    <motion.div initial={{ opacity: 0, y: -6 }} animate={{ opacity: 1, y: 0 }} className="glass" style={{ padding: 10, borderRadius: 14, marginTop: 8 }}>
      <div style={{ display: "flex", gap: 8, marginBottom: 8 }}>
        <input autoFocus className="input-glass" placeholder="Search applications…" value={q} onChange={e => setQ(e.target.value)} />
        <button className="btn-glass" onClick={onClose}>Done</button>
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(88px, 1fr))", gap: 6, maxHeight: 220, overflowY: "auto" }}>
        {list.map(a => (
          <button key={a.path} className="w-listbtn" style={{ flexDirection: "column", margin: 0, width: "100%", padding: 8 }} onClick={() => onPick(a)}>
            <AppIcon path={a.path} size={36} />
            <span style={{ fontSize: 11, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", maxWidth: "100%" }}>{a.name}</span>
          </button>
        ))}
        {list.length === 0 && <div style={{ fontSize: 12, opacity: 0.4, padding: 8 }}>No applications found</div>}
      </div>
    </motion.div>
  );
}

const itemKey = (it: DockItem, i: number) =>
  it.type === "app" || it.type === "folder" ? `${it.type}:${it.path}` : it.type === "widget" ? `w:${it.kind}:${i}` : `sep:${i}`;
const itemLabel = (it: DockItem) =>
  it.type === "app" || it.type === "folder" ? it.name : it.type === "widget" ? (DOCK_WIDGETS.find(w => w.kind === it.kind)?.name ?? it.kind) + " widget" : "Separator";

/* ── Cortex Dock ────────────────────────────────────────── */

export function CortexDockTab() {
  const [cfg, setCfg] = useState<DockConfig | null>(null);
  const [picking, setPicking] = useState(false);
  useEffect(() => { invoke<DockConfig>("dock_get_config").then(setCfg).catch(() => {}); }, []);
  const save = (patch: Partial<DockConfig>) => {
    if (!cfg) return;
    const next = { ...cfg, ...patch };
    setCfg(next);
    invoke<DockConfig>("dock_set_config", { cfg: next }).catch(() => {});
  };
  // Reorder.Group needs stable values: pair each item with a key.
  const keyed = useMemo(() => (cfg?.items ?? []).map((it, i) => ({ k: itemKey(it, i), it })), [cfg?.items]);
  // Reorder locally while dragging; persist once on drop.
  const latest = useRef(cfg);
  latest.current = cfg;
  if (!cfg) return <div className="skeleton" style={{ height: 200 }} />;

  return (
    <div style={{ display: "grid", gridTemplateColumns: "minmax(0,1fr) minmax(0,1fr)", gap: 14, height: "100%", minHeight: 0 }}>
      <div className="glass" style={{ padding: "6px 18px", borderRadius: 18, overflowY: "auto" }}>
        <Row label="Cortex Dock" hint="A Liquid Glass dock with apps and live widgets"><Toggle on={cfg.enabled} set={v => save({ enabled: v })} /></Row>
        <Row label="Position">
          <Seg id="edge" value={cfg.edge} set={v => save({ edge: v })} options={[{ v: "left", l: "Left" }, { v: "bottom", l: "Bottom" }, { v: "right", l: "Right" }, { v: "top", l: "Top" }]} />
        </Row>
        <Row label="Size"><Slider value={cfg.iconSize} min={32} max={80} set={v => save({ iconSize: v })} fmt={v => `${v}pt`} /></Row>
        <Row label="Magnification" hint="Icons swell toward the pointer"><Toggle on={cfg.magnify} set={v => save({ magnify: v })} /></Row>
        <Row label="Automatically hide" hint="Reveal by touching the screen edge"><Toggle on={cfg.autohide} set={v => save({ autohide: v })} /></Row>
        <Row label="Running indicators"><Toggle on={cfg.showRunning} set={v => save({ showRunning: v })} /></Row>
        <Row label="Hide the macOS Dock" hint="Auto-hides the system Dock while this one is on"><Toggle on={cfg.hideSystemDock} set={v => save({ hideSystemDock: v })} /></Row>
      </div>

      <div className="glass" style={{ padding: 16, borderRadius: 18, display: "flex", flexDirection: "column", minHeight: 0 }}>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 10, gap: 8, flexWrap: "wrap" }}>
          <span className="eyebrow">Items · drag to reorder</span>
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            <button className="btn-glass" onClick={() => setPicking(p => !p)}>+ App</button>
            <select className="btn-glass" value="" onChange={e => { if (e.target.value) save({ items: [...cfg.items, { type: "widget", kind: e.target.value as never, config: null }] }); }}
              style={{ appearance: "none", paddingRight: 13 }}>
              <option value="">+ Widget</option>
              {DOCK_WIDGETS.map(w => <option key={w.kind} value={w.kind}>{w.name}</option>)}
            </select>
            <button className="btn-glass" onClick={() => save({ items: [...cfg.items, { type: "separator" }] })}>+ Divider</button>
          </div>
        </div>
        {picking && <AppPicker onClose={() => setPicking(false)} onPick={a => save({ items: [...cfg.items, { type: "app", name: a.name, path: a.path }] })} />}
        <Reorder.Group axis="y" values={keyed} onReorder={v => setCfg({ ...cfg, items: v.map(x => x.it) })}
          style={{ listStyle: "none", padding: 0, margin: "8px 0 0", overflowY: "auto", flex: 1, display: "flex", flexDirection: "column", gap: 4 }}>
          {keyed.map(({ k, it }, i) => (
            <Reorder.Item key={k} value={keyed[i]} className="glass-well"
              onDragEnd={() => latest.current && invoke("dock_set_config", { cfg: latest.current }).catch(() => {})}
              style={{ display: "flex", alignItems: "center", gap: 10, padding: "6px 10px", cursor: "grab" }}
              whileDrag={{ scale: 1.03, boxShadow: "0 10px 30px rgba(0,0,0,0.35)" }}>
              <span style={{ opacity: 0.35, fontSize: 12 }}>⋮⋮</span>
              {it.type === "app" ? <AppIcon path={it.path} size={24} /> : <span style={{ width: 24, textAlign: "center", opacity: 0.6 }}>{it.type === "separator" ? "│" : "◎"}</span>}
              <span style={{ flex: 1, fontSize: 12.5 }}>{itemLabel(it)}</span>
              {it.type === "widget" && it.kind === "weather" && (
                <input className="input-glass" style={{ width: 110, padding: "3px 8px", fontSize: 11.5 }} placeholder="City"
                  defaultValue={String((it.config as Record<string, unknown> | null)?.city ?? "")}
                  onBlur={e => save({ items: cfg.items.map((x, j) => j === i ? { ...it, config: { city: e.target.value } } : x) })} />
              )}
              <button className="w-x" onClick={() => save({ items: cfg.items.filter((_, j) => j !== i) })} title="Remove">×</button>
            </Reorder.Item>
          ))}
        </Reorder.Group>
      </div>
    </div>
  );
}

/* ── macOS Dock ─────────────────────────────────────────── */

type Tile = { kind: string; label: string; path: string };
interface MacDock {
  supported: boolean; autohide: boolean; tilesize: number; magnification: boolean; largesize: number;
  orientation: "bottom" | "left" | "right"; mineffect: "genie" | "scale" | "suck"; showRecents: boolean;
  autohideDelay: number; autohideTimeModifier: number; staticOnly: boolean; launchanim: boolean;
  minimizeToApplication: boolean; showProcessIndicators: boolean; scrollToOpen: boolean; apps: Tile[]; hasBackup: boolean;
}

export function MacDockTab() {
  const [d, setD] = useState<MacDock | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [picking, setPicking] = useState(false);
  useEffect(() => { invoke<MacDock>("macos_dock_get").then(setD).catch(() => setD(null)); }, []);

  const run = async (cmd: string, args: Record<string, unknown>) => {
    setBusy(true); setErr(null);
    try { setD(await invoke<MacDock>(cmd, args)); }
    catch (e) { setErr(typeof e === "string" ? e : "Couldn't update the Dock"); }
    finally { setBusy(false); }
  };
  const set = (patch: Partial<MacDock>) => { if (d) { setD({ ...d, ...patch }); run("macos_dock_set", { patch }); } };
  const setApps = (apps: Tile[]) => { if (d) { setD({ ...d, apps }); run("macos_dock_set_apps", { apps }); } };
  const keyed = useMemo(() => (d?.apps ?? []).map((t, i) => ({ k: `${t.kind}:${t.path}:${t.kind.includes("spacer") ? i : ""}`, t })), [d?.apps]);
  const appsRef = useRef<Tile[]>([]);
  appsRef.current = d?.apps ?? [];

  if (IN_TAURI && d && !d.supported) return (
    <div className="glass" style={{ padding: 24, borderRadius: 18, fontSize: 13, color: "rgba(255,255,255,0.6)" }}>
      Customizing the system Dock is available on macOS. The Cortex Dock works everywhere.
    </div>
  );
  if (!d) return <div className="skeleton" style={{ height: 200 }} />;

  return (
    <div style={{ display: "grid", gridTemplateColumns: "minmax(0,1fr) minmax(0,1fr)", gap: 14, height: "100%", minHeight: 0 }}>
      <div className="glass" style={{ padding: "6px 18px", borderRadius: 18, overflowY: "auto", opacity: busy ? 0.7 : 1, transition: "opacity 200ms" }}>
        <Row label="Size"><Slider value={d.tilesize} min={16} max={128} set={v => set({ tilesize: v })} /></Row>
        <Row label="Magnification"><Toggle on={d.magnification} set={v => set({ magnification: v })} /></Row>
        {d.magnification && <Row label="Magnified size"><Slider value={d.largesize} min={16} max={128} set={v => set({ largesize: v })} /></Row>}
        <Row label="Position on screen">
          <Seg id="ori" value={d.orientation} set={v => set({ orientation: v })} options={[{ v: "left", l: "Left" }, { v: "bottom", l: "Bottom" }, { v: "right", l: "Right" }]} />
        </Row>
        <Row label="Minimize effect">
          <Seg id="min" value={d.mineffect} set={v => set({ mineffect: v })} options={[{ v: "genie", l: "Genie" }, { v: "scale", l: "Scale" }, { v: "suck", l: "Suck" }]} />
        </Row>
        <Row label="Automatically hide and show"><Toggle on={d.autohide} set={v => set({ autohide: v })} /></Row>
        {d.autohide && <>
          <Row label="Reveal delay" hint="0 = instant"><Slider value={d.autohideDelay} min={0} max={2} step={0.05} set={v => set({ autohideDelay: v })} fmt={v => `${v.toFixed(2)}s`} /></Row>
          <Row label="Slide speed"><Slider value={d.autohideTimeModifier} min={0} max={1.5} step={0.05} set={v => set({ autohideTimeModifier: v })} fmt={v => `${v.toFixed(2)}s`} /></Row>
        </>}
        <Row label="Show suggested and recent apps"><Toggle on={d.showRecents} set={v => set({ showRecents: v })} /></Row>
        <Row label="Show only open apps" hint="Hides pinned apps that aren't running"><Toggle on={d.staticOnly} set={v => set({ staticOnly: v })} /></Row>
        <Row label="Minimize into app icon"><Toggle on={d.minimizeToApplication} set={v => set({ minimizeToApplication: v })} /></Row>
        <Row label="Animate opening apps"><Toggle on={d.launchanim} set={v => set({ launchanim: v })} /></Row>
        <Row label="Open-app indicators"><Toggle on={d.showProcessIndicators} set={v => set({ showProcessIndicators: v })} /></Row>
        <Row label="Scroll up on icon to show windows"><Toggle on={d.scrollToOpen} set={v => set({ scrollToOpen: v })} /></Row>
        <div style={{ display: "flex", gap: 8, padding: "12px 0", alignItems: "center" }}>
          <button className="btn-glass" disabled={!d.hasBackup || busy} onClick={() => run("macos_dock_restore", {})}>Restore Original Dock</button>
          {err && <span style={{ fontSize: 12, color: "rgba(var(--accent-rgb),0.9)" }}>{err}</span>}
        </div>
      </div>

      <div className="glass" style={{ padding: 16, borderRadius: 18, display: "flex", flexDirection: "column", minHeight: 0 }}>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 10, gap: 8 }}>
          <span className="eyebrow">Pinned apps · drag to reorder</span>
          <div style={{ display: "flex", gap: 6 }}>
            <button className="btn-glass" onClick={() => setPicking(p => !p)}>+ App</button>
            <button className="btn-glass" onClick={() => setApps([...d.apps, { kind: "spacer", label: "", path: "" }])}>+ Space</button>
            <button className="btn-glass" onClick={() => setApps([...d.apps, { kind: "small-spacer", label: "", path: "" }])}>+ Small Space</button>
          </div>
        </div>
        {picking && <AppPicker onClose={() => setPicking(false)} onPick={a => setApps([...d.apps, { kind: "app", label: a.name, path: a.path }])} />}
        <Reorder.Group axis="y" values={keyed} onReorder={v => setD({ ...d, apps: v.map(x => x.t) })}
          style={{ listStyle: "none", padding: 0, margin: "8px 0 0", overflowY: "auto", flex: 1, display: "flex", flexDirection: "column", gap: 4 }}>
          {keyed.map(({ k, t }, i) => (
            <Reorder.Item key={k} value={keyed[i]} className="glass-well" onDragEnd={() => setApps(appsRef.current)}
              style={{ display: "flex", alignItems: "center", gap: 10, padding: "6px 10px", cursor: "grab" }}
              whileDrag={{ scale: 1.03, boxShadow: "0 10px 30px rgba(0,0,0,0.35)" }}>
              <span style={{ opacity: 0.35, fontSize: 12 }}>⋮⋮</span>
              {t.kind === "app" ? <AppIcon path={t.path} size={24} /> : <span style={{ width: 24, textAlign: "center", opacity: 0.5 }}>{t.kind === "folder" ? "📁" : "␣"}</span>}
              <span style={{ flex: 1, fontSize: 12.5, opacity: t.kind.includes("spacer") ? 0.5 : 1 }}>
                {t.kind === "spacer" ? "Space" : t.kind === "small-spacer" ? "Small space" : t.label}
              </span>
              <button className="w-x" onClick={() => setApps(d.apps.filter((_, j) => j !== i))} title="Remove from Dock">×</button>
            </Reorder.Item>
          ))}
        </Reorder.Group>
        <div style={{ fontSize: 11, opacity: 0.4, marginTop: 8 }}>Changes restart the Dock. Your original layout is backed up the first time.</div>
      </div>
    </div>
  );
}
