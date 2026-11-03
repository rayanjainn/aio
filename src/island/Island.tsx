/**
 * The Island (`index.html#/island`) — a Dynamic-Island-style surface around
 * the notch. Compact: the most important live activity in two "wings" either
 * side of the camera. Hover (or the shortcut): expands into a dashboard with
 * now playing, coding activity, next meeting, battery and a focus timer.
 *
 * Motion is CSS only (width/height/radius transitions on a small element +
 * opacity/transform on content) so it stays smooth even when the window is
 * throttled; data comes from cheap polls that pause while idle.
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "../lib/tauri";
import { usePoll, useNow } from "../hooks/usePoll";
import { knownBrand } from "../widgets/brand";
import { duration, relative } from "../widgets/format";
import { MusicIcon, NextIcon, PauseIcon, PlayIcon, PrevIcon, BoltIcon, Ring } from "../widgets/ui";
import "./island.css";

interface Cfg { enabled: boolean; style: string; music: boolean; coding: boolean; calendar: boolean; battery: boolean; timer: boolean; toasts: boolean; hoverExpand: boolean }
interface Geo { hasNotch: boolean; notchWidth: number; menuBarHeight: number; windowWidth: number }
interface NowPlaying { app: string; state: string; title: string; artist: string; album: string; position: number; duration: number; artwork: string | null }
interface Tool { installed: boolean; todayTokens: number; todayMessages: number; week: number[]; blockTokens: number; blockEndsAt: number | null; lastActive: number | null; active: boolean; model: string; project: string }
interface Coding { claude: Tool; codex: Tool }
interface Agenda { title: string; start: number; end?: number | null; location?: string | null }
interface Stats { battery: { percent: number; charging: boolean; minutesLeft: number | null } | null }
type Toast = { icon: string; text: string; id: number };
type Timer = { endsAt: number | null; total: number; remaining: number; label: string };

/** Time left in the 5-hour block: "2h 10m" / "45m". */
export function blockLeft(sec: number): string {
  const m = Math.max(0, Math.round(sec / 60));
  return m >= 60 ? `${Math.floor(m / 60)}h${m % 60 ? ` ${m % 60}m` : ""}` : `${m}m`;
}

export function fmtTokens(n: number): string {
  if (n >= 1e9) return `${(n / 1e9).toFixed(1)}B`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(n >= 1e7 ? 0 : 1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(n >= 1e4 ? 0 : 1)}K`;
  return String(n);
}

const DEFAULT_CFG: Cfg = { enabled: true, style: "notch", music: true, coding: true, calendar: true, battery: true, timer: true, toasts: true, hoverExpand: true };

function Equalizer({ on, color }: { on: boolean; color?: string }) {
  return <span className={on ? "is-eq on" : "is-eq"} style={color ? { ["--eq" as string]: color } : undefined}><i /><i /><i /><i /></span>;
}

function ToastIcon({ icon }: { icon: string }) {
  const d: Record<string, string> = {
    copy: "M8 8h11v11H8zM5 16V5h11", window: "M3 5h18v14H3zM12 5v14", pause: "M8 5v14M16 5v14",
    volume: "M4 9v6h4l5 4V5L8 9H4zM17 8a5 5 0 0 1 0 8", mute: "M4 9v6h4l5 4V5L8 9H4zM17 9l4 6m0-6-4 6", record: "", warning: "M12 3 2 21h20L12 3zm0 6v5m0 3v.5", check: "M20 6 9 17l-5-5", timer: "M12 8v5l3 2M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z",
  };
  if (icon === "record") return <span className="is-rec" />;
  return <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d={d[icon] ?? d.check} /></svg>;
}

export default function Island() {
  const [cfg, setCfg] = useState<Cfg>(DEFAULT_CFG);
  const [geo, setGeo] = useState<Geo>({ hasNotch: false, notchWidth: 190, menuBarHeight: 32, windowWidth: 760 });
  const [hover, setHover] = useState(false);
  const [pinned, setPinned] = useState(false);
  const [toast, setToast] = useState<Toast | null>(null);
  const [volumeHud, setVolumeHud] = useState<{ level: number; muted: boolean; id: number } | null>(null);
  const [charging, setCharging] = useState<number | null>(null); // flash on plug-in
  const [timer, setTimer] = useState<Timer>(() => {
    try { return JSON.parse(localStorage.getItem("cortex.island.timer") ?? "") as Timer; } catch { return { endsAt: null, total: 25 * 60, remaining: 25 * 60, label: "Focus" }; }
  });
  const pillRef = useRef<HTMLDivElement>(null);
  const expanded = hover || pinned;

  useEffect(() => {
    document.documentElement.classList.add("island-window");
    invoke<Cfg>("island_get_config").then(c => c && setCfg({ ...DEFAULT_CFG, ...c })).catch(() => {});
    invoke<Geo>("island_geometry").then(g => g && setGeo(g)).catch(() => {})
      .finally(() => requestAnimationFrame(() => requestAnimationFrame(() => { invoke("surface_ready").catch(() => {}); })));
    const offs: (() => void)[] = [];
    let toastTimer: ReturnType<typeof setTimeout>;
    import("@tauri-apps/api/event").then(async ({ listen }) => {
      offs.push(await listen<Cfg>("island-config", e => setCfg({ ...DEFAULT_CFG, ...e.payload })));
      offs.push(await listen<boolean>("island-hover", e => setHover(e.payload)));
      offs.push(await listen("island-toggle", () => setPinned(p => !p)));
      offs.push(await listen<{ icon: string; text: string }>("island-toast", e => {
        clearTimeout(toastTimer);
        setToast({ ...e.payload, id: Date.now() });
        toastTimer = setTimeout(() => setToast(null), 2200);
      }));
      offs.push(await listen<{ minutes?: number; action?: string }>("island-timer", e => {
        const { minutes, action } = e.payload ?? {};
        setTimer(t => action === "stop" ? { ...t, endsAt: null, remaining: t.total }
          : { endsAt: Date.now() + (minutes ?? 25) * 60_000, total: (minutes ?? 25) * 60, remaining: (minutes ?? 25) * 60, label: "Focus" });
      }));
    });
    return () => { offs.forEach(f => f()); clearTimeout(toastTimer); };
  }, []);
  useEffect(() => { try { localStorage.setItem("cortex.island.timer", JSON.stringify(timer)); } catch { /* ignore */ } }, [timer]);

  // Data. Polls are cheap; most slow down while compact.
  const { data: np } = usePoll<NowPlaying>("now_playing", undefined, expanded ? 1500 : 3000);
  const { data: coding } = usePoll<Coding>("coding_usage", undefined, expanded ? 4000 : 8000);
  const { data: agenda } = usePoll<Agenda[]>("calendar_upcoming", { limit: 2 }, 60_000);
  const { data: stats } = usePoll<Stats>("sys_stats", undefined, 10_000);
  const now = useNow(1000);

  // Volume HUD: flash the level when it changes (key press or menu-bar slider).
  const { data: vol } = usePoll<[number, boolean] | null>("sys_volume", undefined, 1200);
  const lastVol = useRef<string | null>(null);
  useEffect(() => {
    if (!vol) return;
    const key = `${vol[0]}:${vol[1]}`;
    if (lastVol.current !== null && lastVol.current !== key && cfg.toasts) {
      setVolumeHud({ level: vol[0], muted: vol[1], id: Date.now() });
    }
    lastVol.current = key;
  }, [vol, cfg.toasts]);
  useEffect(() => {
    if (!volumeHud) return;
    const t = setTimeout(() => setVolumeHud(null), 1600);
    return () => clearTimeout(t);
  }, [volumeHud?.id]);

  // Plugging in flashes a charging activity for a few seconds.
  const wasCharging = useRef<boolean | null>(null);
  useEffect(() => {
    const b = stats?.battery;
    if (!b) return;
    if (wasCharging.current === false && b.charging) {
      setCharging(b.percent);
      setTimeout(() => setCharging(null), 4500);
    }
    wasCharging.current = b.charging;
  }, [stats?.battery?.charging, stats?.battery?.percent]);

  // Timer completion
  const timerLeft = timer.endsAt ? Math.max(0, (timer.endsAt - now.getTime()) / 1000) : timer.remaining;
  useEffect(() => {
    if (timer.endsAt && timerLeft <= 0) {
      setTimer(t => ({ ...t, endsAt: null, remaining: t.total }));
      setToast({ icon: "timer", text: "Focus session done", id: Date.now() });
      setTimeout(() => setToast(null), 3500);
    }
  }, [timerLeft, timer.endsAt]);

  const playing = !!np?.app && np.state === "playing";
  const paused = !!np?.app && np.state === "paused";
  const brand = np?.app ? knownBrand(np.app === "Music" ? "apple music" : np.app) : null;
  const working = cfg.coding && (coding?.claude.active || coding?.codex.active);
  const workingTool = coding?.claude.active ? coding.claude : coding?.codex;
  const workingName = coding?.claude.active ? "Claude" : "Codex";
  const nextMeeting = (agenda ?? []).find(a => a.start * 1000 > now.getTime() - 60_000 && a.start * 1000 - now.getTime() < 10 * 60_000);

  // Which activity owns the compact pill (highest priority first).
  type Act = "volume" | "toast" | "timer" | "charging" | "meeting" | "music" | "coding" | "idle";
  const act: Act = volumeHud && cfg.toasts ? "volume"
    : toast && cfg.toasts ? "toast"
    : timer.endsAt && cfg.timer ? "timer"
    : charging !== null && cfg.battery ? "charging"
    : nextMeeting && cfg.calendar ? "meeting"
    : (playing && cfg.music) ? "music"
    : working ? "coding"
    : "idle";

  const H = Math.max(28, Math.round(geo.menuBarHeight));
  const notchW = geo.hasNotch ? geo.notchWidth : 0;
  const wing = act === "toast" || act === "meeting" || act === "volume" ? 132 : act === "idle" ? 0 : 74;
  const compactW = geo.hasNotch ? notchW + wing * 2 : act === "idle" ? 0 : 150 + wing;
  const W = expanded ? 600 : compactW;
  const Hh = expanded ? 262 : H;

  // Report the pill rect (target size) so the backend routes the mouse to it.
  const report = useCallback(() => {
    const wW = geo.windowWidth || 760;
    // Idle on a notch Mac: the notch itself is the hover target.
    const tw = Math.max(W, geo.hasNotch ? notchW : 120), th = Math.max(Hh, H);
    invoke("island_pill", { x: (wW - tw) / 2, y: 0, w: tw, h: th }).catch(() => {});
  }, [W, Hh, H, notchW, geo]);
  useEffect(() => { report(); }, [report]);

  const toggleTimer = () => setTimer(t => t.endsAt
    ? { ...t, endsAt: null, remaining: Math.max(0, (t.endsAt - Date.now()) / 1000) }
    : { ...t, endsAt: Date.now() + t.remaining * 1000 });
  const resetTimer = (m = 25) => setTimer({ endsAt: null, total: m * 60, remaining: m * 60, label: "Focus" });
  const ctl = (action: string) => np?.app && invoke("media_control", { action, app: np.app }).catch(() => {});
  const mmss = (s: number) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;

  // ── Compact wings ──
  const left = (() => {
    switch (act) {
      case "volume": return <span className="is-wing-row"><ToastIcon icon={volumeHud!.muted || volumeHud!.level === 0 ? "mute" : "volume"} /><span>{volumeHud!.muted ? "Muted" : "Volume"}</span></span>;
      case "toast": return <span className="is-wing-row"><ToastIcon icon={toast!.icon} /><span className="is-ellipsis">{toast!.text}</span></span>;
      case "timer": return playing && cfg.music
        ? <span className="is-art-sm">{np?.artwork ? <img src={np.artwork} alt="" /> : <MusicIcon s={12} />}</span>
        : <span className="is-wing-row"><ToastIcon icon="timer" /><span>{timer.label}</span></span>;
      case "charging": return <span className="is-wing-row is-green"><BoltIcon s={13} /><span>Charging</span></span>;
      case "meeting": return <span className="is-wing-row"><span className="is-dot" /><span className="is-ellipsis">{nextMeeting!.title}</span></span>;
      case "music": return <span className="is-art-sm">{np?.artwork ? <img src={np.artwork} alt="" /> : <MusicIcon s={12} />}</span>;
      case "coding": return <span className="is-wing-row"><span className="is-spark" /><span>{workingName}</span></span>;
      default: return null;
    }
  })();
  const right = (() => {
    switch (act) {
      case "volume": return (
        <span className="is-vol"><i style={{ width: `${volumeHud!.muted ? 0 : volumeHud!.level}%` }} /></span>
      );
      // Music keeps the left wing's artwork while a timer owns the right wing.
      case "timer": return <span className="tnum">{mmss(timerLeft)}</span>;
      case "charging": return <span className="tnum is-green">{Math.round(charging ?? 0)}%</span>;
      case "meeting": return <span className="tnum">{relative(nextMeeting!.start, now.getTime()).replace("in ", "")}</span>;
      case "music": return <Equalizer on={playing} color={brand ? `rgb(${brand.rgb})` : undefined} />;
      case "coding": return <span className="tnum is-dim">{fmtTokens(workingTool?.blockTokens ?? 0)}</span>;
      default: return null;
    }
  })();

  const pos = np ? Math.min(np.duration, np.position) : 0;

  return (
    <div className="is-root" data-style={cfg.style}>
      <div ref={pillRef} className={`is-pill${expanded ? " expanded" : ""}${act === "idle" && !expanded ? " idle" : ""}${geo.hasNotch ? " notch" : ""}`}
        style={{ width: W, height: Hh, borderRadius: expanded ? 34 : `0 0 ${H / 2 + 4}px ${H / 2 + 4}px`, ["--notch" as string]: `${notchW}px`, ["--h" as string]: `${H}px` }}
        onClick={() => { if (!cfg.hoverExpand) setPinned(p => !p); }}>
        {/* Compact */}
        <div className="is-compact" aria-hidden={expanded}>
          <div className="is-wing is-left" key={`l-${act}-${toast?.id ?? ""}`}>{left}</div>
          <div className="is-wing is-right" key={`r-${act}`}>{right}</div>
        </div>

        {/* Expanded dashboard */}
        <div className="is-expanded" aria-hidden={!expanded}>
          <div className="is-grid">
            {/* Now playing */}
            <section className={`is-card is-music${brand ? " branded" : ""}`} style={brand ? { ["--brand-rgb" as string]: brand.rgb } : undefined}>
              {np?.app && np.state !== "stopped" ? (
                <>
                  <div className="is-art">{np.artwork ? <img src={np.artwork} alt="" /> : <MusicIcon s={26} />}</div>
                  <div className="is-music-meta">
                    <div className="is-title is-ellipsis">{np.title}</div>
                    <div className="is-sub is-ellipsis">{np.artist}</div>
                    <div className="is-progress"><i style={{ width: `${np.duration ? (pos / np.duration) * 100 : 0}%` }} /></div>
                    <div className="is-times tnum"><span>{duration(pos)}</span><span>-{duration(Math.max(0, np.duration - pos))}</span></div>
                    <div className="is-controls">
                      <button onClick={e => { e.stopPropagation(); ctl("previous"); }} aria-label="Previous"><PrevIcon s={16} /></button>
                      <button className="big" onClick={e => { e.stopPropagation(); ctl("playpause"); }} aria-label={playing ? "Pause" : "Play"}>{playing ? <PauseIcon s={18} /> : <PlayIcon s={18} />}</button>
                      <button onClick={e => { e.stopPropagation(); ctl("next"); }} aria-label="Next"><NextIcon s={16} /></button>
                    </div>
                  </div>
                  <Equalizer on={playing} color={brand ? `rgb(${brand.rgb})` : undefined} />
                </>
              ) : (
                <div className="is-empty"><MusicIcon s={22} /><span>{paused ? "Paused" : "Nothing playing"}</span><small>Spotify or Music</small></div>
              )}
            </section>

            <div className="is-col">
              {/* Coding */}
              <section className="is-card is-coding">
                <div className="is-label"><span className={working ? "is-spark" : "is-spark off"} />Coding today</div>
                <div className="is-coding-row">
                  <div>
                    <div className="is-big tnum">{fmtTokens(coding?.claude.todayTokens ?? 0)}</div>
                    <div className="is-sub is-ellipsis" title={coding?.claude.model}>Claude{coding?.claude.model ? ` · ${coding.claude.model}` : ""}</div>
                  </div>
                  <div>
                    <div className="is-big tnum">{fmtTokens(coding?.codex.todayTokens ?? 0)}</div>
                    <div className="is-sub">Codex</div>
                  </div>
                  {coding?.claude.blockEndsAt ? (
                    <Ring value={1 - Math.max(0, coding.claude.blockEndsAt - now.getTime() / 1000) / (5 * 3600)} size={42} stroke={4.5}>
                      <span className="tnum" style={{ fontSize: 9.5, fontWeight: 700 }}>{blockLeft(coding.claude.blockEndsAt - now.getTime() / 1000)}</span>
                    </Ring>
                  ) : null}
                </div>
                <div className="is-sub is-ellipsis">{working ? `${workingName} is working${workingTool?.project ? ` in ${workingTool.project}` : ""}…` : coding?.claude.lastActive ? `Last active ${relative(coding.claude.lastActive, now.getTime())}` : "No sessions yet today"}</div>
              </section>

              <div className="is-row2">
                {/* Timer */}
                <section className="is-card is-timer" onClick={e => { e.stopPropagation(); toggleTimer(); }} onContextMenu={e => { e.preventDefault(); resetTimer(); }}>
                  <Ring value={timer.endsAt ? timerLeft / timer.total : 1} size={40} stroke={4}>
                    {timer.endsAt ? <PauseIcon s={12} /> : <PlayIcon s={12} />}
                  </Ring>
                  <div>
                    <div className="is-mid tnum">{mmss(timerLeft)}</div>
                    <div className="is-sub">{timer.endsAt ? "Focus · tap to pause" : "Tap to focus"}</div>
                  </div>
                </section>
                {/* Next up / battery */}
                <section className="is-card is-next">
                  {agenda && agenda[0] ? (
                    <>
                      <div className="is-label">Next</div>
                      <div className="is-mid is-ellipsis">{agenda[0].title}</div>
                      <div className="is-sub">{relative(agenda[0].start, now.getTime())}</div>
                    </>
                  ) : stats?.battery ? (
                    <>
                      <div className="is-label">Battery</div>
                      <div className="is-mid tnum">{stats.battery.charging ? "⚡︎ " : ""}{Math.round(stats.battery.percent)}%</div>
                      <div className="is-sub">{stats.battery.minutesLeft ? `${Math.floor(stats.battery.minutesLeft / 60)}h ${stats.battery.minutesLeft % 60}m` : stats.battery.charging ? "Charging" : ""}</div>
                    </>
                  ) : (
                    <>
                      <div className="is-label">{now.toLocaleDateString([], { weekday: "long" })}</div>
                      <div className="is-mid tnum">{now.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</div>
                      <div className="is-sub">{now.toLocaleDateString([], { month: "long", day: "numeric" })}</div>
                    </>
                  )}
                </section>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

