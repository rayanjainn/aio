/**
 * The Cortex Dock window (`index.html#/dock`): a Liquid Glass bar of apps,
 * folders and live mini widgets.
 *
 * Layout: the window = bar + transparent headroom on the side facing away from
 * the screen edge. The native glass is inset to cover only the bar, so icons
 * can magnify up into the headroom exactly like the macOS Dock.
 * Magnification writes transforms straight to the DOM on pointer move (no React
 * re-render per frame); show/hide is a CSS transition.
 */
import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { invoke } from "../lib/tauri";
import { usePoll, useNow } from "../hooks/usePoll";
import { AppIcon } from "../components/icons";
import { Ring, WeatherIcon, PlayIcon, PauseIcon, MusicIcon, loadColor } from "../widgets/ui";
import type { SysStats } from "../widgets/kinds/system";
import type { DockConfig, DockItem } from "./types";
import { knownBrand } from "../widgets/brand";
import "../widgets/widgets.css";
import "./dock.css";

const PAD = 8;          // bar padding
const MAX_SCALE = 1.6;  // peak magnification (with headroom)

function Tile({ size, label, onClick, onContext, running, children }: {
  size: number; label: string; onClick?: () => void; onContext?: (e: React.MouseEvent) => void; running?: boolean; children: ReactNode;
}) {
  const [bounce, setBounce] = useState(0);
  return (
    // Native tooltip: draws outside the content-sized dock window.
    <div className="dk-tile" data-mag title={label} style={{ width: size, height: size }} onContextMenu={onContext}
      onClick={() => { if (onClick) { setBounce(b => b + 1); onClick(); } }}>
      <div key={bounce} className={bounce ? "dk-icon dk-bounce" : "dk-icon"}>{children}</div>
      {running && <span className="dk-dot" />}
    </div>
  );
}

/* ── Mini widgets ───────────────────────────────────────── */

function MiniClock({ size }: { size: number }) {
  const now = useNow(1000);
  return (
    <div className="dk-mini" style={{ height: size, padding: `0 ${size * 0.28}px` }}>
      <div className="tnum" style={{ fontSize: size * 0.36, fontWeight: 600, letterSpacing: "-0.03em", lineHeight: 1 }}>
        {now.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }).replace(/\s?[AP]M/i, "")}
      </div>
      <div style={{ fontSize: size * 0.19, opacity: 0.55, marginTop: 3, fontWeight: 500 }}>
        {now.toLocaleDateString([], { weekday: "short", day: "numeric" })}
      </div>
    </div>
  );
}

function MiniStat({ kind, size }: { kind: "cpu" | "battery"; size: number }) {
  const { data } = usePoll<SysStats>("sys_stats", undefined, kind === "cpu" ? 2000 : 20_000);
  if (kind === "battery" && data && !data.battery) return null;
  const v = kind === "cpu" ? (data?.cpu ?? 0) / 100 : (data?.battery?.percent ?? 0) / 100;
  return (
    <div className="dk-mini" style={{ width: size, height: size }}>
      <Ring value={v} size={size * 0.78} stroke={size * 0.085} color={kind === "cpu" ? loadColor(v) : undefined}>
        <span className="tnum" style={{ fontSize: size * 0.22, fontWeight: 700, lineHeight: 1 }}>{Math.round(v * 100)}</span>
        <span style={{ fontSize: size * 0.13, opacity: 0.55, marginTop: 1 }}>{kind === "cpu" ? "CPU" : data?.battery?.charging ? "⚡︎" : "BAT"}</span>
      </Ring>
    </div>
  );
}

function MiniMusic({ size }: { size: number }) {
  const { data } = usePoll<{ app: string; state: string; title: string; artist: string; artwork: string | null }>("now_playing", undefined, 2500);
  const playing = data?.state === "playing";
  const active = !!data?.app && data.state !== "stopped";
  const brand = active ? knownBrand(data!.app === "Music" ? "apple music" : data!.app) : null;
  return (
    <div className={`dk-mini dk-music${brand ? " branded" : ""}`}
      style={{ height: size, width: active ? size * 3.6 : size, ...(brand ? { ["--brand-rgb" as string]: brand.rgb } : {}) }}>
      <div className="dk-art" style={{ width: size * 0.78, height: size * 0.78, borderRadius: size * 0.2 }}>
        {data?.artwork ? <img src={data.artwork} alt="" /> : <MusicIcon s={size * 0.34} />}
      </div>
      {active && (
        <>
          <div style={{ flex: 1, minWidth: 0, textAlign: "left" }}>
            <div className="dk-ellipsis" style={{ fontSize: 12, fontWeight: 600 }}>{data!.title}</div>
            <div className="dk-ellipsis" style={{ fontSize: 11, opacity: 0.55 }}>{data!.artist}</div>
          </div>
          <span className={playing ? "dk-eq on" : "dk-eq"}><i /><i /><i /></span>
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
  return (
    <div className="dk-mini" style={{ height: size, padding: `0 ${size * 0.22}px`, flexDirection: "row", gap: size * 0.12 }}>
      <WeatherIcon code={data?.code ?? 2} day={data?.isDay ?? true} size={size * 0.46} />
      {data && <span className="tnum" style={{ fontSize: size * 0.3, fontWeight: 600 }}>{Math.round(data.tempC)}°</span>}
    </div>
  );
}

/* ── Bar ────────────────────────────────────────────────── */

export default function Dock() {
  const [cfg, setCfg] = useState<DockConfig | null>(null);
  const [shown, setShown] = useState(true);
  const [native, setNative] = useState(false);
  const barRef = useRef<HTMLDivElement>(null);
  const { data: running } = usePoll<{ name: string; path: string }[]>("get_running_apps", undefined, 3000);
  const runningSet = new Set((running ?? []).map(r => r.path.replace(/\/$/, "")));

  useEffect(() => {
    document.documentElement.classList.add("dock-window");
    invoke<DockConfig>("dock_get_config").then(setCfg).catch(() => {});
    invoke<{ native: boolean }>("glass_info").then(g => setNative(!!g.native)).catch(() => {});
    const offs: (() => void)[] = [];
    import("@tauri-apps/api/event").then(async ({ listen }) => {
      offs.push(await listen<DockConfig>("dock-config", e => setCfg(e.payload)));
      offs.push(await listen<boolean>("dock-reveal", e => setShown(e.payload)));
    });
    return () => offs.forEach(f => f());
  }, []);

  const vertical = cfg?.edge === "left" || cfg?.edge === "right";
  const sz = cfg?.iconSize ?? 48;
  // Headroom only exists with native glass (it can be inset to the bar);
  // with whole-window vibrancy the bar must fill the window.
  const head = cfg?.magnify && native ? Math.ceil(sz * (MAX_SCALE - 1)) + 6 : 0;
  const side = cfg?.magnify && native ? Math.ceil(sz * 0.4) : 0;
  const maxScale = native ? MAX_SCALE : 1.18;

  // Size the native window to the bar (layout size — immune to transforms).
  useLayoutEffect(() => {
    const el = barRef.current;
    if (!el || !cfg) return;
    let last = "";
    const report = () => {
      const bw = el.offsetWidth, bh = el.offsetHeight;
      const [w, h] = vertical ? [bw + head, bh + side * 2] : [bw + side * 2, bh + head];
      // inset = [top, right, bottom, left]
      const inset = cfg.edge === "bottom" ? [head, side, 0, side] : cfg.edge === "top" ? [0, side, head, side]
        : cfg.edge === "left" ? [side, head, side, 0] : [side, 0, side, head];
      const key = `${w}x${h}:${inset.join(",")}`;
      if (key === last) return;
      last = key;
      invoke("dock_resize", { w, h, inset }).catch(() => {});
    };
    report();
    const ro = new ResizeObserver(report);
    ro.observe(el);
    return () => ro.disconnect();
  }, [cfg, head, side, vertical]);

  // Magnification: Gaussian falloff around the pointer, written directly to
  // each tile's transform (transition smooths it; no per-frame React work).
  const onMove = (e: React.PointerEvent) => {
    if (!cfg?.magnify || !barRef.current) return;
    const p = vertical ? e.clientY : e.clientX;
    const origin = cfg.edge === "bottom" ? "50% 100%" : cfg.edge === "top" ? "50% 0%" : cfg.edge === "left" ? "0% 50%" : "100% 50%";
    for (const el of barRef.current.querySelectorAll<HTMLElement>("[data-mag]")) {
      const r = el.getBoundingClientRect();
      const c = vertical ? r.top + r.height / 2 : r.left + r.width / 2;
      const d = (p - c) / (sz * 1.35);
      const s = 1 + (maxScale - 1) * Math.exp(-d * d);
      el.style.transformOrigin = origin;
      el.style.transform = `scale(${s.toFixed(3)})`;
      el.style.zIndex = s > 1.05 ? "2" : "";
    }
  };
  const onLeave = () => barRef.current?.querySelectorAll<HTMLElement>("[data-mag]").forEach(el => { el.style.transform = ""; el.style.zIndex = ""; });

  if (!cfg) return null;

  const context = async (e: React.MouseEvent, index?: number) => {
    e.preventDefault();
    e.stopPropagation();
    const { Menu, MenuItem, PredefinedMenuItem } = await import("@tauri-apps/api/menu");
    const items = [];
    if (index !== undefined) {
      const it = cfg.items[index];
      if (it.type === "app" || it.type === "folder") items.push(await MenuItem.new({ text: "Show in Finder", action: () => invoke("reveal_in_finder", { path: it.path }).catch(() => {}) }));
      if (it.type === "app" && runningSet.has(it.path.replace(/\/$/, ""))) {
        items.push(await MenuItem.new({ text: "Hide", action: () => invoke("app_action", { path: it.path, action: "hide" }).catch(() => {}) }));
        items.push(await MenuItem.new({ text: "Quit", action: () => invoke("app_action", { path: it.path, action: "quit" }).catch(() => {}) }));
      }
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
        return <div key={`sep${i}`} className="dk-sep" style={vertical ? { width: sz * 0.62, height: 1 } : { height: sz * 0.62, width: 1 }} />;
      case "app":
      case "folder":
        return (
          <Tile key={`${it.path}${i}`} size={sz} label={it.name}
            running={cfg.showRunning && runningSet.has(it.path.replace(/\/$/, ""))}
            onClick={() => invoke("launch_path", { path: it.path }).catch(() => {})} onContext={e => context(e, i)}>
            {it.type === "app" ? <AppIcon path={it.path} size={sz} /> : <div className="dk-folder" style={{ width: sz, height: sz, fontSize: sz * 0.55 }}>📁</div>}
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

  const justify = cfg.edge === "bottom" ? "flex-end" : cfg.edge === "top" ? "flex-start" : "center";
  const align = cfg.edge === "left" ? "flex-start" : cfg.edge === "right" ? "flex-end" : "center";
  return (
    <div className="dk-root" onContextMenu={e => context(e)}
      style={{ flexDirection: vertical ? "row" : "column", justifyContent: vertical ? align : justify, alignItems: vertical ? justify : align,
        padding: vertical ? `${side}px 0` : `0 ${side}px` }}>
      <div ref={barRef} className={`dk-bar dk-${cfg.edge}${shown ? "" : " dk-hidden"}${native ? " native" : ""}`}
        onPointerMove={onMove} onPointerLeave={onLeave}
        style={{ flexDirection: vertical ? "column" : "row", padding: PAD, gap: Math.round(sz * 0.14), borderRadius: Math.round(sz * 0.36 + PAD) }}>
        {cfg.items.map(render)}
      </div>
    </div>
  );
}
