/**
 * Widgets & Dock studio — gallery with live previews, placed-widget manager
 * and per-widget settings. Extra tabs (dock editors) register via `extraTabs`.
 */
import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { invoke } from "../lib/tauri";
import { useGlassPointer } from "../hooks/useGlassPointer";
import { KINDS, KIND_MAP, type Field, type WidgetKind } from "../widgets/registry";
import { SIZES, sizeClass, type SizeClass, type Widget, type WidgetConfig } from "../widgets/types";
import { WidgetCard } from "../widgets/WidgetCard";
import { CloseIcon } from "./icons";

export interface StudioTab { id: string; label: string; render: () => ReactNode }

const PREVIEW_SCALE: Record<SizeClass, number> = { s: 0.82, m: 0.62, l: 0.48 };

function fakeWidget(k: WidgetKind, size: SizeClass): Widget {
  return { id: `preview-${k.kind}`, kind: k.kind, x: 0, y: 0, w: SIZES[size].w, h: SIZES[size].h, layer: "desktop", locked: false,
    config: { ...(k.defaults ?? {}), ...(k.kind === "weather" ? { city: "Cupertino" } : {}),
      ...(k.kind === "countdown" ? { title: "New Year", date: `${new Date().getFullYear() + 1}-01-01` } : {}),
      ...(k.kind === "todos" ? { items: [{ id: "1", text: "Ship the dock", done: false }, { id: "2", text: "Water plants", done: true }] } : {}),
      ...(k.kind === "notes" ? { text: "Liquid glass everywhere ✨" } : {}) } };
}

function Preview({ k, size }: { k: WidgetKind; size: SizeClass }) {
  const w = useMemo(() => fakeWidget(k, size), [k, size]);
  const sc = PREVIEW_SCALE[size];
  return (
    <div style={{ width: SIZES[size].w * sc, height: SIZES[size].h * sc, position: "relative", pointerEvents: "none" }}>
      <div style={{ position: "absolute", left: 0, top: 0, width: SIZES[size].w, height: SIZES[size].h, transform: `scale(${sc})`, transformOrigin: "0 0" }}>
        <div style={{ position: "relative", width: "100%", height: "100%" }}>
          <WidgetCard widget={w} setConfig={() => {}} preview />
        </div>
      </div>
    </div>
  );
}

function GalleryCard({ k, onAdd }: { k: WidgetKind; onAdd: (size: SizeClass) => Promise<void> }) {
  const [size, setSize] = useState<SizeClass>(k.sizes[0]);
  const [added, setAdded] = useState(false);
  return (
    <motion.div layout className="glass" style={{ padding: 14, display: "flex", flexDirection: "column", gap: 12, borderRadius: 18 }}
      whileHover={{ y: -3 }} transition={{ type: "spring", stiffness: 400, damping: 28 }}>
      <div style={{ height: 190, display: "flex", alignItems: "center", justifyContent: "center" }}>
        <AnimatePresence mode="wait">
          <motion.div key={size} initial={{ opacity: 0, scale: 0.9 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0, scale: 0.94 }}
            transition={{ type: "spring", stiffness: 380, damping: 30 }}>
            <Preview k={k} size={size} />
          </motion.div>
        </AnimatePresence>
      </div>
      <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        <div style={{ minWidth: 0 }}>
          <div style={{ fontSize: 13.5, fontWeight: 600 }}>{k.name}</div>
          <div style={{ fontSize: 11.5, color: "rgba(255,255,255,0.45)" }}>{k.description}</div>
        </div>
        <div style={{ display: "flex", gap: 8, alignItems: "center", justifyContent: "space-between" }}>
          {k.sizes.length > 1 ? (
            <div className="segmented glass-well">
              {k.sizes.map(s => (
                <button key={s} data-active={s === size} onClick={() => setSize(s)} style={{ padding: "3px 8px", fontSize: 11 }}>
                  {s === size && <motion.span layoutId={`sz-${k.kind}`} className="liquid-pill" transition={{ type: "spring", stiffness: 500, damping: 36 }} />}
                  {s.toUpperCase()}
                </button>
              ))}
            </div>
          ) : <span />}
          <button className="btn-glass btn-accent" style={{ padding: "5px 14px" }}
            onClick={async () => { await onAdd(size); setAdded(true); setTimeout(() => setAdded(false), 1400); }}>
            {added ? "Added ✓" : "Add"}
          </button>
        </div>
      </div>
    </motion.div>
  );
}

function FieldEditor({ f, value, onChange }: { f: Field; value: unknown; onChange: (v: unknown) => void }) {
  const [apps, setApps] = useState<{ name: string; path: string }[]>([]);
  const [q, setQ] = useState("");
  useEffect(() => { if (f.type === "apps") invoke<{ name: string; path: string }[]>("list_installed_apps").then(setApps).catch(() => {}); }, [f.type]);
  const [draft, setDraft] = useState<string>(() =>
    f.type === "zones" || f.type === "repos" ? ((value as string[] | undefined) ?? []).join(f.type === "zones" ? ", " : "\n") : String(value ?? ""));
  const commitText = () => onChange(f.type === "number" ? (draft === "" ? null : Number(draft)) : draft);

  switch (f.type) {
    case "toggle":
      return <button className="toggle" data-on={!!value} onClick={() => onChange(!value)}><span /></button>;
    case "select":
      return (
        <div className="segmented glass-well">
          {f.options!.map(o => (
            <button key={o.value} data-active={value === o.value} onClick={() => onChange(o.value)}>
              {value === o.value && <motion.span layoutId={`f-${f.key}`} className="liquid-pill" />}{o.label}
            </button>
          ))}
        </div>
      );
    case "zones":
      return <input className="input-glass" value={draft} placeholder="Europe/London, Asia/Tokyo" onChange={e => setDraft(e.target.value)}
        onBlur={() => onChange(draft.split(",").map(s => s.trim()).filter(Boolean))} />;
    case "repos":
      return <textarea className="input-glass" rows={3} value={draft} placeholder={"Auto-detect, or one path per line\n~/code/aio"} onChange={e => setDraft(e.target.value)}
        onBlur={() => onChange(draft.split("\n").map(s => s.trim()).filter(Boolean))} style={{ resize: "vertical", fontFamily: "var(--font-mono)", fontSize: 12 }} />;
    case "apps": {
      const sel = (value as { name: string; path: string }[] | undefined) ?? [];
      const has = (p: string) => sel.some(a => a.path === p);
      const list = apps.filter(a => !q || a.name.toLowerCase().includes(q.toLowerCase()));
      return (
        <div style={{ width: "100%" }}>
          <input className="input-glass" placeholder="Search apps…" value={q} onChange={e => setQ(e.target.value)} style={{ marginBottom: 6 }} />
          <div className="glass-well" style={{ maxHeight: 180, overflowY: "auto", padding: 4 }}>
            {list.map(a => (
              <label key={a.path} style={{ display: "flex", alignItems: "center", gap: 8, padding: "4px 6px", fontSize: 12.5, cursor: "pointer" }}>
                <input type="checkbox" checked={has(a.path)} onChange={() => onChange(has(a.path) ? sel.filter(x => x.path !== a.path) : [...sel, a])} />
                {a.name}
              </label>
            ))}
            {list.length === 0 && <div style={{ fontSize: 12, opacity: 0.4, padding: 6 }}>No apps found</div>}
          </div>
        </div>
      );
    }
    default:
      return <input className="input-glass" type={f.type === "date" ? "date" : f.type === "number" ? "number" : "text"} value={draft}
        placeholder={f.placeholder} onChange={e => setDraft(e.target.value)} onBlur={commitText}
        onKeyDown={e => e.key === "Enter" && (e.target as HTMLInputElement).blur()} />;
  }
}

function WidgetEditor({ w, onClose }: { w: Widget; onClose: () => void }) {
  const k = KIND_MAP[w.kind];
  const [cur, setCur] = useState(w);
  useEffect(() => setCur(w), [w]);
  const patch = (p: Partial<Widget> & { config?: WidgetConfig }) => {
    setCur(c => ({ ...c, ...p, config: p.config ? { ...c.config, ...p.config } : c.config }));
    invoke("widget_update", { id: w.id, patch: p }).catch(() => {});
  };
  const size = sizeClass(cur.w, cur.h);
  return (
    <motion.div initial={{ opacity: 0, x: 24 }} animate={{ opacity: 1, x: 0 }} exit={{ opacity: 0, x: 24 }}
      transition={{ type: "spring", stiffness: 380, damping: 34 }}
      className="glass" style={{ width: 320, flexShrink: 0, padding: 16, display: "flex", flexDirection: "column", gap: 14, borderRadius: 18, overflowY: "auto" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <div className="display" style={{ fontSize: 15, fontWeight: 600 }}>{k?.name ?? w.kind}</div>
        <button className="btn-glass btn-icon" onClick={onClose}><CloseIcon s={12} /></button>
      </div>
      <div style={{ display: "flex", justifyContent: "center", padding: "6px 0" }}>{k && <Preview k={k} size={size} />}</div>
      <SettingRow label="Size">
        <div className="segmented glass-well">
          {(k?.sizes ?? ["s"]).map(s => (
            <button key={s} data-active={s === size} onClick={() => patch({ w: SIZES[s].w, h: SIZES[s].h })}>
              {s === size && <motion.span layoutId="ed-size" className="liquid-pill" />}{SIZES[s].label}
            </button>
          ))}
        </div>
      </SettingRow>
      <SettingRow label="Layer">
        <div className="segmented glass-well">
          {(["desktop", "floating"] as const).map(l => (
            <button key={l} data-active={cur.layer === l} onClick={() => patch({ layer: l })}>
              {cur.layer === l && <motion.span layoutId="ed-layer" className="liquid-pill" />}{l === "desktop" ? "Desktop" : "Floating"}
            </button>
          ))}
        </div>
      </SettingRow>
      <SettingRow label="Lock position">
        <button className="toggle" data-on={cur.locked} onClick={() => patch({ locked: !cur.locked })}><span /></button>
      </SettingRow>
      {(k?.fields ?? []).map(f => (
        <div key={f.key} style={{ display: "flex", flexDirection: f.type === "toggle" || f.type === "select" ? "row" : "column", gap: 6,
          justifyContent: "space-between", alignItems: f.type === "toggle" || f.type === "select" ? "center" : "stretch" }}>
          <span style={{ fontSize: 12.5, color: "rgba(255,255,255,0.6)" }}>{f.label}</span>
          <FieldEditor key={`${w.id}-${f.key}`} f={f} value={cur.config?.[f.key]} onChange={v => patch({ config: { [f.key]: v } })} />
        </div>
      ))}
      <button className="btn-glass btn-danger" style={{ marginTop: "auto" }}
        onClick={() => { invoke("widget_remove", { id: w.id }).catch(() => {}); onClose(); }}>Remove Widget</button>
    </motion.div>
  );
}

function SettingRow({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10 }}>
      <span style={{ fontSize: 12.5, color: "rgba(255,255,255,0.6)" }}>{label}</span>{children}
    </div>
  );
}

function WidgetsTab({ focusId }: { focusId: string | null }) {
  const [placed, setPlaced] = useState<Widget[]>([]);
  const [visible, setVisible] = useState(true);
  const [edit, setEdit] = useState(false);
  const [selected, setSelected] = useState<string | null>(focusId);
  const [cat, setCat] = useState<string>("All");
  useEffect(() => setSelected(focusId), [focusId]);

  const refresh = useCallback(() => {
    invoke<Widget[]>("widgets_list").then(setPlaced).catch(() => {});
    invoke<boolean>("widgets_visible").then(setVisible).catch(() => {});
  }, []);
  useEffect(() => {
    refresh();
    let off: (() => void) | undefined;
    import("@tauri-apps/api/event").then(({ listen }) => listen("widgets-changed", refresh)).then(u => { off = u; }).catch(() => {});
    return () => { off?.(); invoke("widgets_edit_mode", { enabled: false }).catch(() => {}); };
  }, [refresh]);

  const add = async (k: WidgetKind, size: SizeClass) => {
    const w = await invoke<Widget>("widget_add", { kind: k.kind, w: SIZES[size].w, h: SIZES[size].h, config: k.defaults ?? {} });
    if (w) { setPlaced(p => [...p, w]); if (k.fields?.length) setSelected(w.id); }
  };
  const cats = ["All", "Essentials", "Productivity", "System", "Developer"];
  const sel = placed.find(p => p.id === selected) ?? null;

  return (
    <div style={{ display: "flex", gap: 14, height: "100%", minHeight: 0 }}>
      <div style={{ flex: 1, minWidth: 0, overflowY: "auto", paddingRight: 4 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 14, flexWrap: "wrap" }}>
          <div className="segmented glass-well">
            {cats.map(c => (
              <button key={c} data-active={cat === c} onClick={() => setCat(c)}>
                {cat === c && <motion.span layoutId="cat" className="liquid-pill" transition={{ type: "spring", stiffness: 500, damping: 36 }} />}{c}
              </button>
            ))}
          </div>
          <div style={{ flex: 1 }} />
          <button className="btn-glass" onClick={() => { const v = !edit; setEdit(v); invoke("widgets_edit_mode", { enabled: v }).catch(() => {}); }}>
            {edit ? "Done" : "Arrange"}
          </button>
          <button className="btn-glass" onClick={() => invoke<boolean>("widgets_set_visible", { visible: !visible }).then(setVisible).catch(() => {})}>
            {visible ? "Hide All" : "Show All"}
          </button>
        </div>

        {placed.length > 0 && (
          <>
            <div className="eyebrow" style={{ margin: "4px 2px 8px" }}>On your desktop · {placed.length}</div>
            <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 18 }}>
              {placed.map(p => (
                <motion.button layout key={p.id} className="btn-glass" data-active={p.id === selected} onClick={() => setSelected(p.id)}
                  style={{ borderColor: p.id === selected ? "rgba(255,255,255,0.4)" : undefined }}>
                  {KIND_MAP[p.kind]?.name ?? p.kind}
                  <span style={{ opacity: 0.45, fontSize: 10.5 }}>{sizeClass(p.w, p.h).toUpperCase()}{p.layer === "floating" ? " · float" : ""}</span>
                </motion.button>
              ))}
            </div>
          </>
        )}

        <div className="eyebrow" style={{ margin: "4px 2px 8px" }}>Gallery</div>
        <motion.div layout style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(290px, 1fr))", gap: 12 }}>
          {KINDS.filter(k => cat === "All" || k.category === cat).map(k => (
            <GalleryCard key={k.kind} k={k} onAdd={s => add(k, s)} />
          ))}
        </motion.div>
      </div>
      <AnimatePresence>{sel && <WidgetEditor key={sel.id} w={sel} onClose={() => setSelected(null)} />}</AnimatePresence>
    </div>
  );
}

export default function Studio({ tab, onClose, extraTabs = [] }: { tab: string; onClose: () => void; extraTabs?: StudioTab[] }) {
  const focusId = tab.startsWith("widget:") ? tab.slice(7) : null;
  const [active, setActive] = useState(focusId ? "widgets" : tab);
  useEffect(() => { setActive(tab.startsWith("widget:") ? "widgets" : tab); }, [tab]);
  const ref = useRef<HTMLDivElement>(null);
  useGlassPointer(ref);
  const tabs: StudioTab[] = [{ id: "widgets", label: "Widgets", render: () => <WidgetsTab focusId={focusId} /> }, ...extraTabs];
  const cur = tabs.find(t => t.id === active) ?? tabs[0];

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape" && !(e.target as HTMLElement).closest("input, textarea")) onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div ref={ref} className="glass-window" data-cortex-overlay style={{ position: "fixed", inset: 0, zIndex: 900 }}>
      <div data-tauri-drag-region style={{ display: "flex", alignItems: "center", gap: 14, height: 52, padding: "0 14px 0 18px", flexShrink: 0, borderBottom: "1px solid rgba(255,255,255,0.08)" }}>
        <span className="display" style={{ fontSize: 15, fontWeight: 600, pointerEvents: "none" }}>Studio</span>
        <div className="segmented glass-well">
          {tabs.map(t => (
            <button key={t.id} data-active={t.id === cur.id} onClick={() => setActive(t.id)}>
              {t.id === cur.id && <motion.span layoutId="studio-tab" className="liquid-pill" transition={{ type: "spring", stiffness: 500, damping: 36 }} />}
              {t.label}
            </button>
          ))}
        </div>
        <div style={{ flex: 1 }} data-tauri-drag-region />
        <button className="btn-glass btn-icon" onClick={onClose} title="Close (Esc)"><CloseIcon s={13} /></button>
      </div>
      <AnimatePresence mode="wait">
        <motion.div key={cur.id} initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -6 }}
          transition={{ duration: 0.22, ease: [0.16, 1, 0.3, 1] }} style={{ flex: 1, minHeight: 0, padding: 16 }}>
          {cur.render()}
        </motion.div>
      </AnimatePresence>
    </div>
  );
}
