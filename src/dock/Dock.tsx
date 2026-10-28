/**
 * The Cortex Dock window (`index.html#/dock`): a Liquid Glass bar of apps,
 * folders and live mini widgets. Icons swell toward the pointer like the
 * macOS Dock; launching bounces. The window is sized to the bar's content.
 */
import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { motion, useMotionValue, useSpring, useTransform, type MotionValue } from "framer-motion";
import { invoke } from "../lib/tauri";
import { usePoll, useNow } from "../hooks/usePoll";
import { AppIcon } from "../components/icons";
import { Ring, WeatherIcon, PlayIcon, PauseIcon, MusicIcon, loadColor } from "../widgets/ui";
import type { SysStats } from "../widgets/kinds/system";
import type { DockConfig, DockItem } from "./types";
import "../widgets/widgets.css";
import "./dock.css";

const PAD = 10;

function useMagnify(pointer: MotionValue<number>, ref: React.RefObject<HTMLElement>, vertical: boolean, enabled: boolean, size: number) {
  const dist = useTransform(pointer, p => {
    const r = ref.current?.getBoundingClientRect();
    if (!r || p === Infinity) return Infinity;
    return p - (vertical ? r.top + r.height / 2 : r.left + r.width / 2);
  });
  // Gaussian falloff over ~2.5 icons; capped so icons stay inside the bar padding.
  const scale = useTransform(dist, d => !enabled || !Number.isFinite(d) ? 1 : 1 + 0.36 * Math.exp(-((d / (size * 1.25)) ** 2)));
  return useSpring(scale, { stiffness: 420, damping: 30, mass: 0.35 });
}

function Tile({ pointer, vertical, cfg, children, label, onClick, onContext, running }: {
  pointer: MotionValue<number>; vertical: boolean; cfg: DockConfig; children: ReactNode; label: string;
  onClick?: () => void; onContext?: (e: React.MouseEvent) => void; running?: boolean;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const scale = useMagnify(pointer, ref, vertical, cfg.magnify, cfg.iconSize);
  const [bounce, setBounce] = useState(0);
  return (
    // Native tooltip: draws outside the content-sized dock window, unlike an HTML label.
    <div ref={ref} className="dk-tile" title={label} style={{ width: cfg.iconSize, height: cfg.iconSize }} onContextMenu={onContext}>
      <motion.div style={{ scale, width: "100%", height: "100%", transformOrigin: "center" }}
        animate={bounce ? { y: vertical ? 0 : [0, -16, 0, -7, 0], x: vertical ? [0, 12, 0, 5, 0] : 0 } : undefined}
        transition={{ duration: 0.75, ease: "easeOut" }}
        whileTap={{ scale: 0.86 }}
        onClick={() => { if (onClick) { setBounce(b => b + 1); onClick(); } }}>
        {children}
      </motion.div>
      {cfg.showRunning && running && <span className={`dk-dot dk-dot-${cfg.edge}`} />}
    </div>
  );
}

/* ── Mini widgets ───────────────────────────────────────── */

function MiniClock({ size }: { size: number }) {
  const now = useNow(1000);
  return (
    <div className="dk-mini" style={{ width: size * 1.6, height: size }}>
      <div className="tnum" style={{ fontSize: size * 0.34, fontWeight: 600, letterSpacing: "-0.02em", lineHeight: 1 }}>
        {now.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }).replace(/\s?[AP]M/i, "")}
      </div>
      <div style={{ fontSize: size * 0.2, opacity: 0.6, marginTop: 2 }}>{now.toLocaleDateString([], { weekday: "short", day: "numeric" })}</div>
    </div>
  );
}

function MiniStat({ kind, size }: { kind: "cpu" | "battery"; size: number }) {
  const { data } = usePoll<SysStats>("sys_stats", undefined, kind === "cpu" ? 2000 : 20_000);
  const v = kind === "cpu" ? (data?.cpu ?? 0) / 100 : (data?.battery?.percent ?? 0) / 100;
  if (kind === "battery" && data && !data.battery) return null;
  return (
    <div className="dk-mini" style={{ width: size, height: size }}>
      <Ring value={v} size={size * 0.86} stroke={size * 0.09} color={kind === "cpu" ? loadColor(v) : v < 0.2 && !data?.battery?.charging ? "var(--accent)" : undefined}>
        <span className="tnum" style={{ fontSize: size * 0.22, fontWeight: 700 }}>{Math.round(v * 100)}</span>
        <span style={{ fontSize: size * 0.14, opacity: 0.55, marginTop: -2 }}>{kind === "cpu" ? "CPU" : data?.battery?.charging ? "⚡︎" : "%"}</span>
      </Ring>
    </div>
  );
}

function MiniMusic({ size }: { size: number }) {
  const { data } = usePoll<{ app: string; state: string; title: string; artist: string; artwork: string | null }>("now_playing", undefined, 2500);
  const playing = data?.state === "playing";
  const active = !!data?.app && data.state !== "stopped";
  return (
    <div className="dk-mini" style={{ width: active ? size * 3.4 : size, height: size, flexDirection: "row", gap: 8, justifyContent: "flex-start", transition: "width 400ms var(--ease-out)" }}>
      <div className="w-art" style={{ width: size * 0.82, height: size * 0.82, borderRadius: size * 0.2 }}>
        {data?.artwork ? <img src={data.artwork} alt="" style={{ width: "100%", height: "100%", objectFit: "cover" }} /> : <MusicIcon s={size * 0.36} />}
      </div>
      {active && (
        <>
          <div style={{ flex: 1, minWidth: 0, textAlign: "left" }}>
            <div style={{ fontSize: 11.5, fontWeight: 600, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{data!.title}</div>
            <div style={{ fontSize: 10.5, opacity: 0.55, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{data!.artist}</div>
          </div>
          <button className="w-iconbtn" onClick={e => { e.stopPropagation(); invoke("media_control", { action: "playpause", app: data!.app }).catch(() => {}); }}>
            {playing ? <PauseIcon s={12} /> : <PlayIcon s={12} />}
          </button>
        </>
      )}
    </div>
  );
}

function MiniWeather({ size, city }: { size: number; city: string }) {
  const { data } = usePoll<{ tempC: number; code: number; isDay: boolean }>("weather_get", { city }, 15 * 60_000, [city]);
  if (!city || !data) return <div className="dk-mini" style={{ width: size, height: size }}><WeatherIcon code={2} size={size * 0.5} /></div>;
  return (
    <div className="dk-mini" style={{ width: size * 1.3, height: size }}>
      <WeatherIcon code={data.code} day={data.isDay} size={size * 0.42} />
      <span className="tnum" style={{ fontSize: size * 0.26, fontWeight: 600 }}>{Math.round(data.tempC)}°</span>
    </div>
  );
}

/* ── Bar ────────────────────────────────────────────────── */

export default function Dock() {
  const [cfg, setCfg] = useState<DockConfig | null>(null);
  const [shown, setShown] = useState(true);
  const barRef = useRef<HTMLDivElement>(null);
  const pointer = useMotionValue(Infinity);
  const { data: running } = usePoll<{ name: string; path: string }[]>("get_running_apps", undefined, 3000);
  const runningSet = new Set((running ?? []).map(r => r.path.replace(/\/$/, "")));

  useEffect(() => {
    document.documentElement.classList.add("dock-window");
    invoke<DockConfig>("dock_get_config").then(setCfg).catch(() => {});
    const offs: (() => void)[] = [];
    import("@tauri-apps/api/event").then(async ({ listen }) => {
      offs.push(await listen<DockConfig>("dock-config", e => setCfg(e.payload)));
      offs.push(await listen<boolean>("dock-reveal", e => setShown(e.payload)));
    });
    return () => offs.forEach(f => f());
  }, []);

  // Size the native window to the bar.
  useLayoutEffect(() => {
    const el = barRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      const r = el.getBoundingClientRect();
      invoke("dock_resize", { w: Math.ceil(r.width), h: Math.ceil(r.height) }).catch(() => {});
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, [cfg?.edge, !!cfg]);

  if (!cfg) return null;
  const vertical = cfg.edge === "left" || cfg.edge === "right";
  const sz = cfg.iconSize;

  const context = async (e: React.MouseEvent, index?: number) => {
    e.preventDefault();
    e.stopPropagation();
    const { Menu, MenuItem, PredefinedMenuItem } = await import("@tauri-apps/api/menu");
    const items = [];
    if (index !== undefined) {
      const it = cfg.items[index];
      if (it.type === "app" || it.type === "folder") items.push(await MenuItem.new({ text: "Show in Finder", action: () => invoke("reveal_in_finder", { path: it.path }).catch(() => {}) }));
      items.push(await MenuItem.new({ text: "Remove from Dock", action: () => {
        const next = { ...cfg, items: cfg.items.filter((_, i) => i !== index) };
        setCfg(next); invoke("dock_set_config", { cfg: next }).catch(() => {});
      } }));
      items.push(await PredefinedMenuItem.new({ item: "Separator" }));
    }
    items.push(await MenuItem.new({ text: cfg.autohide ? "Turn Hiding Off" : "Turn Hiding On", action: () => invoke("dock_set_config", { cfg: { ...cfg, autohide: !cfg.autohide } }).catch(() => {}) }));
    items.push(await MenuItem.new({ text: cfg.magnify ? "Turn Magnification Off" : "Turn Magnification On", action: () => invoke("dock_set_config", { cfg: { ...cfg, magnify: !cfg.magnify } }).catch(() => {}) }));
    items.push(await MenuItem.new({ text: "Dock Settings…", action: () => invoke("open_studio", { tab: "dock" }).catch(() => {}) }));
    (await Menu.new({ items })).popup().catch(() => {});
  };

  const render = (it: DockItem, i: number) => {
    switch (it.type) {
      case "separator":
        return <div key={`sep${i}`} className="dk-sep" style={vertical ? { width: sz * 0.7, height: 1 } : { height: sz * 0.7, width: 1 }} />;
      case "app":
      case "folder":
        return (
          <Tile key={`${it.path}${i}`} pointer={pointer} vertical={vertical} cfg={cfg} label={it.name}
            running={runningSet.has(it.path.replace(/\/$/, ""))}
            onClick={() => invoke("launch_path", { path: it.path }).catch(() => {})} onContext={e => context(e, i)}>
            {it.type === "app" ? <AppIcon path={it.path} size={sz} /> : <div className="dk-folder" style={{ width: sz, height: sz }}>📁</div>}
          </Tile>
        );
      case "widget": {
        const body = it.kind === "clock" ? <MiniClock size={sz} />
          : it.kind === "music" ? <MiniMusic size={sz} />
          : it.kind === "weather" ? <MiniWeather size={sz} city={String((it.config as Record<string, unknown> | null)?.city ?? "")} />
          : <MiniStat kind={it.kind} size={sz} />;
        return <div key={`w${i}`} onContextMenu={e => context(e, i)} className="dk-widget">{body}</div>;
      }
    }
  };

  const hiddenOffset = cfg.edge === "bottom" ? { y: sz + 40 } : cfg.edge === "top" ? { y: -(sz + 40) } : cfg.edge === "left" ? { x: -(sz + 40) } : { x: sz + 40 };
  return (
    <div className="dk-root" onContextMenu={e => context(e)}>
      <motion.div ref={barRef} className="dk-bar rim-light"
        initial={{ opacity: 0, scale: 0.92, ...hiddenOffset }}
        animate={shown ? { opacity: 1, scale: 1, x: 0, y: 0 } : { opacity: 0, scale: 0.96, ...hiddenOffset }}
        transition={{ type: "spring", stiffness: 380, damping: 32 }}
        onMouseMove={e => pointer.set(vertical ? e.clientY : e.clientX)}
        onMouseLeave={() => pointer.set(Infinity)}
        style={{ flexDirection: vertical ? "column" : "row", padding: PAD, gap: sz * 0.16, borderRadius: sz * 0.42 + PAD }}>
        {cfg.items.map(render)}
      </motion.div>
    </div>
  );
}
