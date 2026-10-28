import { useEffect, useMemo, useState } from "react";
import { motion, AnimatePresence } from "framer-motion";
import type { WidgetProps } from "../types";
import { useNow, usePoll } from "../../hooks/usePoll";
import { cityOf, offsetLabel, partsIn, relative, timeIn } from "../format";
import { IconButton, PauseIcon, PlayIcon, ResetIcon, Ring, WEmpty, WTitle } from "../ui";

/* ── Clock ──────────────────────────────────────────────── */

function AnalogFace({ tz, size, seconds }: { tz?: string; size: number; seconds: boolean }) {
  const now = useNow(1000);
  const { h, m, s } = partsIn(now, tz);
  const hourA = (h % 12) * 30 + m * 0.5, minA = m * 6 + s * 0.1, secA = s * 6;
  const night = h < 6 || h >= 19;
  const hand = (angle: number, len: number, w: number, color: string, tail = 0) => (
    <line x1="50" y1={50 + tail} x2="50" y2={50 - len} stroke={color} strokeWidth={w} strokeLinecap="round"
      style={{ transform: `rotate(${angle}deg)`, transformOrigin: "50px 50px", transition: angle === 0 ? "none" : "transform 300ms cubic-bezier(.4,2.2,.5,1)" }} />
  );
  return (
    <svg width={size} height={size} viewBox="0 0 100 100" style={{ flexShrink: 0 }}>
      <defs>
        <radialGradient id="face" cx="50%" cy="35%" r="75%">
          <stop offset="0%" stopColor={night ? "rgba(40,44,60,0.95)" : "rgba(255,255,255,0.96)"} />
          <stop offset="100%" stopColor={night ? "rgba(14,15,22,0.95)" : "rgba(222,226,236,0.94)"} />
        </radialGradient>
      </defs>
      <circle cx="50" cy="50" r="48" fill="url(#face)" stroke="rgba(255,255,255,0.25)" strokeWidth="0.8" />
      {Array.from({ length: 12 }, (_, i) => {
        const a = (i * Math.PI) / 6;
        const big = i % 3 === 0;
        return <line key={i} x1={50 + Math.sin(a) * (big ? 37 : 39)} y1={50 - Math.cos(a) * (big ? 37 : 39)} x2={50 + Math.sin(a) * 43} y2={50 - Math.cos(a) * 43}
          stroke={night ? "rgba(255,255,255,0.7)" : "rgba(20,20,28,0.75)"} strokeWidth={big ? 2.4 : 1.2} strokeLinecap="round" />;
      })}
      {hand(hourA, 22, 4.2, night ? "#fff" : "#16161c")}
      {hand(minA, 33, 3, night ? "#fff" : "#16161c")}
      {seconds && hand(secA, 37, 1.3, "var(--accent)", 8)}
      <circle cx="50" cy="50" r="2.6" fill={seconds ? "var(--accent)" : night ? "#fff" : "#16161c"} />
    </svg>
  );
}

export function ClockWidget({ size, config }: WidgetProps) {
  const now = useNow(1000);
  const tz: string | undefined = config.tz || undefined;
  const zones: string[] = (config.zones ?? []).filter(Boolean);
  const style = config.style ?? "analog";
  const seconds = config.seconds !== false;
  const label = config.label || (tz ? cityOf(tz) : "");

  if (size === "s") {
    return style === "digital" ? (
      <div className="w-center" style={{ gap: 2 }}>
        <div className="w-eyebrow">{label || now.toLocaleDateString([], { weekday: "long" })}</div>
        <div className="w-huge tnum">{timeIn(now, tz, { hour: "numeric", minute: "2-digit", hour12: config.h24 ? false : undefined }).replace(/\s?[AP]M/i, "")}</div>
        <div className="w-sub">{now.toLocaleDateString([], { month: "short", day: "numeric", timeZone: tz })}</div>
      </div>
    ) : (
      <div className="w-center" style={{ gap: 4 }}>
        <AnalogFace tz={tz} size={size === "s" ? 118 : 140} seconds={seconds} />
        {label && <div className="w-sub">{label}</div>}
      </div>
    );
  }

  const list = zones.length ? zones : ["America/Los_Angeles", "Europe/London", "Asia/Tokyo"];
  return (
    <div style={{ display: "flex", gap: 16, height: "100%", flexDirection: size === "l" ? "column" : "row", alignItems: size === "l" ? "stretch" : "center" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
        <AnalogFace tz={tz} size={size === "l" ? 150 : 124} seconds={seconds} />
        {size === "l" && (
          <div>
            <div className="w-big tnum">{timeIn(now, tz)}</div>
            <div className="w-sub">{now.toLocaleDateString([], { weekday: "long", month: "long", day: "numeric", timeZone: tz })}</div>
          </div>
        )}
      </div>
      <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: size === "l" ? 4 : 6, minWidth: 0 }}>
        {list.slice(0, size === "l" ? 5 : 3).map(z => {
          const { h } = partsIn(now, z);
          return (
            <div key={z} className="w-row">
              <span style={{ fontSize: 13, color: "rgba(255,255,255,0.88)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                {h < 6 || h >= 19 ? "☾" : "☀︎"} {cityOf(z)}
              </span>
              <span style={{ display: "flex", gap: 8, alignItems: "baseline" }}>
                <span className="w-faint" style={{ fontSize: 10.5 }}>{offsetLabel(now, z)}</span>
                <span className="tnum" style={{ fontSize: 14, fontWeight: 600 }}>{timeIn(now, z)}</span>
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

/* ── Calendar ───────────────────────────────────────────── */

type Agenda = { title: string; start: number; end?: number | null; location?: string | null; calendar?: string | null };

function MonthGrid({ now, compact }: { now: Date; compact?: boolean }) {
  const y = now.getFullYear(), mo = now.getMonth();
  const first = new Date(y, mo, 1);
  const startDow = (first.getDay() + 6) % 7; // Monday-first
  const days = new Date(y, mo + 1, 0).getDate();
  const cells = Array.from({ length: Math.ceil((startDow + days) / 7) * 7 }, (_, i) => i - startDow + 1);
  return (
    <div style={{ display: "grid", gridTemplateColumns: "repeat(7, 1fr)", gap: compact ? 1 : 3, textAlign: "center", fontSize: compact ? 10 : 11.5 }}>
      {["M", "T", "W", "T", "F", "S", "S"].map((d, i) => <div key={i} className="w-faint" style={{ fontWeight: 600, fontSize: 9.5 }}>{d}</div>)}
      {cells.map((d, i) => {
        const today = d === now.getDate();
        const valid = d >= 1 && d <= days;
        return (
          <div key={i} className="tnum" style={{
            height: compact ? 15 : 22, lineHeight: compact ? "15px" : "22px", borderRadius: 99,
            color: !valid ? "transparent" : today ? "#111" : i % 7 >= 5 ? "rgba(255,255,255,0.45)" : "rgba(255,255,255,0.85)",
            background: today ? "rgba(255,255,255,0.92)" : "transparent", fontWeight: today ? 700 : 500,
          }}>{valid ? d : "·"}</div>
        );
      })}
    </div>
  );
}

export function CalendarWidget({ size }: WidgetProps) {
  const now = useNow(60_000);
  const { data } = usePoll<Agenda[]>("calendar_upcoming", { limit: 6 }, 120_000);
  const events = data ?? [];
  const next = events[0];
  const day = (
    <div>
      <div className="w-eyebrow" style={{ color: "rgba(var(--accent-rgb),0.85)" }}>{now.toLocaleDateString([], { weekday: "long" })}</div>
      <div className="w-huge tnum" style={{ lineHeight: 1 }}>{now.getDate()}</div>
    </div>
  );
  const list = (n: number) => events.length === 0
    ? <div className="w-faint" style={{ fontSize: 12 }}>No upcoming events</div>
    : events.slice(0, n).map((e, i) => (
      <div key={i} style={{ display: "flex", gap: 8, alignItems: "stretch", padding: "3px 0" }}>
        <span style={{ width: 3, borderRadius: 2, background: i === 0 ? "rgba(255,255,255,0.85)" : "rgba(255,255,255,0.25)" }} />
        <div style={{ minWidth: 0 }}>
          <div style={{ fontSize: 12.5, fontWeight: 600, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{e.title}</div>
          <div className="w-faint" style={{ fontSize: 11 }}>
            {new Date(e.start * 1000).toLocaleString([], { weekday: "short", hour: "numeric", minute: "2-digit" })} · {relative(e.start)}
          </div>
        </div>
      </div>
    ));

  if (size === "s") return (
    <div style={{ display: "flex", flexDirection: "column", justifyContent: "space-between", height: "100%" }}>
      {day}
      {next ? (
        <div>
          <div style={{ fontSize: 12.5, fontWeight: 600, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{next.title}</div>
          <div className="w-faint" style={{ fontSize: 11 }}>{relative(next.start)}</div>
        </div>
      ) : <MonthGrid now={now} compact />}
    </div>
  );
  if (size === "m") return (
    <div style={{ display: "flex", gap: 16, height: "100%" }}>
      <div style={{ width: 150, flexShrink: 0 }}>
        <div className="w-eyebrow" style={{ marginBottom: 4 }}>{now.toLocaleDateString([], { month: "long" })}</div>
        <MonthGrid now={now} compact />
      </div>
      <div style={{ flex: 1, minWidth: 0, overflow: "hidden" }}>{day}<div style={{ marginTop: 6 }}>{list(2)}</div></div>
    </div>
  );
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12, height: "100%" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-end" }}>
        {day}
        <div className="w-sub">{now.toLocaleDateString([], { month: "long", year: "numeric" })}</div>
      </div>
      <MonthGrid now={now} />
      <div style={{ flex: 1, overflow: "hidden" }}>{list(3)}</div>
    </div>
  );
}

/* ── Countdown ──────────────────────────────────────────── */

export function CountdownWidget({ size, config }: WidgetProps) {
  const now = useNow(1000);
  const target = config.date ? new Date(config.date) : null;
  if (!target || isNaN(target.getTime())) return <WEmpty>Pick a date in widget settings</WEmpty>;
  const diff = Math.max(0, target.getTime() - now.getTime());
  const d = Math.floor(diff / 86400000), h = Math.floor(diff / 3600000) % 24, m = Math.floor(diff / 60000) % 60, s = Math.floor(diff / 1000) % 60;
  const title = config.title || "Countdown";
  const unit = (v: number, l: string) => (
    <div style={{ textAlign: "center" }}>
      <div className="tnum" style={{ fontSize: size === "s" ? 22 : 30, fontWeight: 700, letterSpacing: "-0.02em" }}>{String(v).padStart(2, "0")}</div>
      <div className="w-faint" style={{ fontSize: 9.5, textTransform: "uppercase", letterSpacing: "0.08em" }}>{l}</div>
    </div>
  );
  return (
    <div className="w-center" style={{ gap: 8 }}>
      <div className="w-eyebrow">{title}</div>
      {diff === 0 ? <div className="w-big">It's here 🎉</div> : size === "s" ? (
        <>
          <div className="w-huge tnum" style={{ lineHeight: 1 }}>{d}</div>
          <div className="w-sub">{d === 1 ? "day" : "days"} · {String(h).padStart(2, "0")}:{String(m).padStart(2, "0")}</div>
        </>
      ) : (
        <div style={{ display: "flex", gap: 18 }}>{unit(d, "days")}{unit(h, "hrs")}{unit(m, "min")}{unit(s, "sec")}</div>
      )}
      <div className="w-faint" style={{ fontSize: 11 }}>{target.toLocaleDateString([], { weekday: "short", month: "short", day: "numeric", year: "numeric" })}</div>
    </div>
  );
}

/* ── Focus timer (Pomodoro) ─────────────────────────────── */

type FocusState = { phase: "focus" | "break"; endsAt: number | null; remaining: number; rounds: number };

export function FocusWidget({ widget, size, config }: WidgetProps) {
  const focusMin = Number(config.minutes) || 25, breakMin = Number(config.breakMinutes) || 5;
  const key = `cortex.focus.${widget.id}`;
  const fresh = (): FocusState => ({ phase: "focus", endsAt: null, remaining: focusMin * 60, rounds: 0 });
  const [st, setSt] = useState<FocusState>(() => {
    try { return { ...fresh(), ...JSON.parse(localStorage.getItem(key) ?? "{}") }; } catch { return fresh(); }
  });
  useEffect(() => { try { localStorage.setItem(key, JSON.stringify(st)); } catch { /* ignore */ } }, [key, st]);
  const now = useNow(250);
  const left = st.endsAt ? Math.max(0, (st.endsAt - now.getTime()) / 1000) : st.remaining;
  const total = (st.phase === "focus" ? focusMin : breakMin) * 60;

  // Phase complete → flip focus/break automatically.
  useEffect(() => {
    if (st.endsAt && left <= 0) {
      const nextPhase = st.phase === "focus" ? "break" : "focus";
      setSt(s => ({ phase: nextPhase, endsAt: null, remaining: (nextPhase === "focus" ? focusMin : breakMin) * 60, rounds: s.rounds + (s.phase === "focus" ? 1 : 0) }));
    }
  }, [left, st.endsAt, st.phase, focusMin, breakMin]);

  const running = !!st.endsAt;
  const toggle = () => setSt(s => s.endsAt ? { ...s, endsAt: null, remaining: Math.max(0, (s.endsAt - Date.now()) / 1000) } : { ...s, endsAt: Date.now() + s.remaining * 1000 });
  const reset = () => setSt(fresh());
  const mm = Math.floor(left / 60), ss = Math.floor(left % 60);
  const color = st.phase === "focus" ? "rgba(var(--accent-rgb),0.95)" : "rgba(255,255,255,0.85)";
  const ringSize = size === "s" ? 108 : 132;

  return (
    <div style={{ display: "flex", alignItems: "center", justifyContent: size === "s" ? "center" : "space-around", height: "100%", gap: 16, flexDirection: size === "l" ? "column" : "row" }}>
      <Ring value={left / total} size={ringSize} stroke={size === "s" ? 8 : 10} color={color}>
        <div className="tnum" style={{ fontSize: size === "s" ? 24 : 30, fontWeight: 700, letterSpacing: "-0.02em" }}>{mm}:{String(ss).padStart(2, "0")}</div>
        <div className="w-faint" style={{ fontSize: 10, textTransform: "uppercase", letterSpacing: "0.1em" }}>{st.phase}</div>
      </Ring>
      <div style={{ display: "flex", flexDirection: size === "s" ? "row" : "column", gap: 10, alignItems: "center", position: size === "s" ? "absolute" : "static", bottom: 10 }}>
        {size !== "s" && <div className="w-sub">{st.rounds} {st.rounds === 1 ? "session" : "sessions"} today</div>}
        <div style={{ display: "flex", gap: 8 }}>
          <IconButton big onClick={toggle} title={running ? "Pause" : "Start"}>{running ? <PauseIcon s={16} /> : <PlayIcon s={16} />}</IconButton>
          {size !== "s" && <IconButton big onClick={reset} title="Reset"><ResetIcon s={15} /></IconButton>}
        </div>
      </div>
      {size === "s" && (
        <div style={{ position: "absolute", inset: 0 }} data-nodrag onClick={toggle} title={running ? "Pause" : "Start"} />
      )}
    </div>
  );
}

/* ── Search pill ────────────────────────────────────────── */

export function SearchWidget({ size }: WidgetProps) {
  const hints = useMemo(() => ["what was I doing yesterday?", "> kill port 3000", "10 usd to inr", "roadmap.md", "? summarize my week"], []);
  const [i, setI] = useState(0);
  useEffect(() => { const t = setInterval(() => setI(x => (x + 1) % hints.length), 3200); return () => clearInterval(t); }, [hints.length]);
  const open = async () => {
    const { invoke } = await import("../../lib/tauri");
    invoke("open_studio", { tab: "palette" }).catch(() => {});
  };
  return (
    <div className="w-center" style={{ gap: 10 }}>
      {size !== "s" && <WTitle>Cortex</WTitle>}
      <button data-nodrag onClick={open} className="w-search">
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="11" cy="11" r="7" /><path d="m20 20-3.5-3.5" /></svg>
        <span style={{ flex: 1, textAlign: "left", position: "relative", height: 18, overflow: "hidden" }}>
          <AnimatePresence mode="popLayout">
            <motion.span key={i} initial={{ y: 14, opacity: 0 }} animate={{ y: 0, opacity: 1 }} exit={{ y: -14, opacity: 0 }}
              transition={{ type: "spring", stiffness: 300, damping: 26 }} style={{ position: "absolute", whiteSpace: "nowrap" }}>
              {size === "s" ? "Search" : hints[i]}
            </motion.span>
          </AnimatePresence>
        </span>
        {size !== "s" && <kbd className="mono" style={{ fontSize: 10.5, opacity: 0.6 }}>⌘K</kbd>}
      </button>
    </div>
  );
}
