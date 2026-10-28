/**
 * Shared widget primitives: progress rings, sparklines, weather glyphs and a
 * handful of control icons. All SVG, all `currentColor`-aware.
 */
import type { ReactNode, SVGProps } from "react";

/* ── Ring gauge ─────────────────────────────────────────── */

export function Ring({ value, size = 64, stroke = 7, color = "rgba(255,255,255,0.92)", track = "rgba(255,255,255,0.12)", children }: {
  value: number; size?: number; stroke?: number; color?: string; track?: string; children?: ReactNode;
}) {
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  const v = Math.max(0, Math.min(1, Number.isFinite(value) ? value : 0));
  return (
    <div style={{ position: "relative", width: size, height: size, flexShrink: 0 }}>
      <svg width={size} height={size} style={{ transform: "rotate(-90deg)", overflow: "visible" }}>
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={track} strokeWidth={stroke} />
        {/* CSS transition, not a JS spring: keeps animating in throttled windows. */}
        <circle
          cx={size / 2} cy={size / 2} r={r} fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round"
          strokeDasharray={c} strokeDashoffset={c * (1 - v)}
          style={{ transition: "stroke-dashoffset 900ms cubic-bezier(.16,1,.3,1), stroke 300ms", filter: "drop-shadow(0 0 5px rgba(255,255,255,0.18))" }}
        />
      </svg>
      {children && (
        <div style={{ position: "absolute", inset: 0, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center" }}>
          {children}
        </div>
      )}
    </div>
  );
}

/** Monochrome by default; the accent only appears when something needs attention. */
export function loadColor(v: number): string {
  return v > 0.85 ? "var(--accent)" : "rgba(255,255,255,0.92)";
}

/* ── Sparkline ──────────────────────────────────────────── */

export function Sparkline({ data, width = 120, height = 32, color = "rgba(255,255,255,0.85)", fill = true, max }: {
  data: number[]; width?: number; height?: number; color?: string; fill?: boolean; max?: number;
}) {
  if (data.length < 2) return <svg width={width} height={height} />;
  const hi = max ?? Math.max(...data, 1e-9);
  const step = width / (data.length - 1);
  const pts = data.map((d, i) => [i * step, height - 2 - (Math.min(d, hi) / hi) * (height - 4)] as const);
  const line = pts.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
  const id = `sg${Math.round(hi * 1000)}${data.length}`;
  return (
    <svg width={width} height={height} style={{ display: "block", overflow: "visible" }}>
      <defs>
        <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={color} stopOpacity="0.35" />
          <stop offset="100%" stopColor={color} stopOpacity="0" />
        </linearGradient>
      </defs>
      {fill && <path d={`${line} L${width},${height} L0,${height} Z`} fill={`url(#${id})`} />}
      <path d={line} fill="none" stroke={color} strokeWidth={1.6} strokeLinejoin="round" strokeLinecap="round" />
    </svg>
  );
}

/* ── Weather ────────────────────────────────────────────── */

/** WMO weather code → short label. */
export function weatherLabel(code: number): string {
  if (code === 0) return "Clear";
  if (code <= 2) return "Partly Cloudy";
  if (code === 3) return "Cloudy";
  if (code <= 48) return "Fog";
  if (code <= 57) return "Drizzle";
  if (code <= 67) return "Rain";
  if (code <= 77) return "Snow";
  if (code <= 82) return "Showers";
  if (code <= 86) return "Snow Showers";
  return "Thunderstorm";
}

type WKind = "sun" | "moon" | "partly" | "partlyNight" | "cloud" | "fog" | "rain" | "snow" | "storm";
function weatherKind(code: number, day: boolean): WKind {
  if (code === 0) return day ? "sun" : "moon";
  if (code <= 2) return day ? "partly" : "partlyNight";
  if (code === 3) return "cloud";
  if (code <= 48) return "fog";
  if (code <= 67 || (code >= 80 && code <= 82)) return "rain";
  if (code <= 77 || code <= 86) return "snow";
  return "storm";
}

export function WeatherIcon({ code, day = true, size = 28 }: { code: number; day?: boolean; size?: number }) {
  const k = weatherKind(code, day);
  // Monochrome glyphs, SF Symbols style.
  const sun = "rgba(255,255,255,0.95)", cloud = "rgba(255,255,255,0.92)", cloudDim = "rgba(255,255,255,0.55)", drop = "rgba(255,255,255,0.8)";
  const Cloud = ({ dx = 0, dy = 0, fill = cloud }: { dx?: number; dy?: number; fill?: string }) => (
    <path transform={`translate(${dx} ${dy})`} fill={fill}
      d="M7.5 19h9.2a4.3 4.3 0 0 0 .5-8.57A5.5 5.5 0 0 0 6.6 11.1 4 4 0 0 0 7.5 19Z" />
  );
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" style={{ flexShrink: 0, overflow: "visible", filter: "drop-shadow(0 1px 4px rgba(0,0,0,0.25))" }}>
      {(k === "sun" || k === "partly") && (
        <g>
          <circle cx={k === "sun" ? 12 : 9} cy={k === "sun" ? 12 : 9} r={k === "sun" ? 4.6 : 3.8} fill={sun} />
          {Array.from({ length: 8 }, (_, i) => {
            const a = (i * Math.PI) / 4, cx = k === "sun" ? 12 : 9, cy = k === "sun" ? 12 : 9, r1 = k === "sun" ? 7.2 : 6, r2 = k === "sun" ? 9.4 : 7.8;
            return <line key={i} x1={cx + Math.cos(a) * r1} y1={cy + Math.sin(a) * r1} x2={cx + Math.cos(a) * r2} y2={cy + Math.sin(a) * r2} stroke={sun} strokeWidth={1.6} strokeLinecap="round" />;
          })}
        </g>
      )}
      {(k === "moon" || k === "partlyNight") && (
        <path fill="rgba(255,255,255,0.9)" transform={k === "partlyNight" ? "translate(-3 -3) scale(0.85)" : undefined}
          d="M15.5 3.5a8.5 8.5 0 1 0 5 15.1A7 7 0 0 1 15.5 3.5Z" />
      )}
      {(k === "partly" || k === "partlyNight") && <Cloud dx={2} dy={1} />}
      {k === "cloud" && <><Cloud dx={2.5} dy={-3} fill={cloudDim} /><Cloud /></>}
      {k === "fog" && (
        <g stroke={cloudDim} strokeWidth={1.8} strokeLinecap="round">
          <line x1="4" y1="9" x2="20" y2="9" /><line x1="2.5" y1="13" x2="18" y2="13" /><line x1="6" y1="17" x2="21" y2="17" />
        </g>
      )}
      {(k === "rain" || k === "storm" || k === "snow") && <Cloud dy={-3} />}
      {k === "rain" && (
        <g stroke={drop} strokeWidth={1.7} strokeLinecap="round">
          <line x1="9" y1="18.5" x2="8" y2="21.5" /><line x1="13" y1="18.5" x2="12" y2="21.5" /><line x1="17" y1="18.5" x2="16" y2="21.5" />
        </g>
      )}
      {k === "snow" && (
        <g fill="#fff"><circle cx="9" cy="20" r="1.1" /><circle cx="13" cy="21.3" r="1.1" /><circle cx="17" cy="20" r="1.1" /></g>
      )}
      {k === "storm" && <path d="M13.2 16.5 10.5 20.6h2.6l-1.4 3 3.6-4.6h-2.6l1.5-2.5Z" fill={sun} />}
    </svg>
  );
}

/* ── Icons ──────────────────────────────────────────────── */

type IP = SVGProps<SVGSVGElement> & { s?: number };
const ib = ({ s = 16, ...r }: IP) => ({ width: s, height: s, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 1.9, strokeLinecap: "round" as const, strokeLinejoin: "round" as const, ...r });

export const PlayIcon  = (p: IP) => <svg {...ib(p)} fill="currentColor" stroke="none"><path d="M7 4.8v14.4a1 1 0 0 0 1.5.86l12-7.2a1 1 0 0 0 0-1.72l-12-7.2A1 1 0 0 0 7 4.8Z" /></svg>;
export const PauseIcon = (p: IP) => <svg {...ib(p)} fill="currentColor" stroke="none"><rect x="6" y="4.5" width="4" height="15" rx="1.2" /><rect x="14" y="4.5" width="4" height="15" rx="1.2" /></svg>;
export const NextIcon  = (p: IP) => <svg {...ib(p)} fill="currentColor" stroke="none"><path d="M4 6.2v11.6a.8.8 0 0 0 1.2.7L13 13.6v4.2a.8.8 0 0 0 1.2.7l8-5.8a.8.8 0 0 0 0-1.4l-8-5.8a.8.8 0 0 0-1.2.7v4.2L5.2 5.5a.8.8 0 0 0-1.2.7Z" /></svg>;
export const PrevIcon  = (p: IP) => <svg {...ib(p)} fill="currentColor" stroke="none" style={{ transform: "scaleX(-1)" }}><path d="M4 6.2v11.6a.8.8 0 0 0 1.2.7L13 13.6v4.2a.8.8 0 0 0 1.2.7l8-5.8a.8.8 0 0 0 0-1.4l-8-5.8a.8.8 0 0 0-1.2.7v4.2L5.2 5.5a.8.8 0 0 0-1.2.7Z" /></svg>;
export const PlusIcon  = (p: IP) => <svg {...ib(p)}><path d="M12 5v14M5 12h14" /></svg>;
export const MinusIcon = (p: IP) => <svg {...ib(p)}><path d="M5 12h14" /></svg>;
export const CheckIcon = (p: IP) => <svg {...ib(p)}><path d="M20 6 9 17l-5-5" /></svg>;
export const ResetIcon = (p: IP) => <svg {...ib(p)}><path d="M3 12a9 9 0 1 0 3-6.7L3 8" /><path d="M3 3v5h5" /></svg>;
export const BoltIcon  = (p: IP) => <svg {...ib(p)} fill="currentColor" stroke="none"><path d="M13 2 4.5 13.5H11L10 22l8.5-11.5H12L13 2Z" /></svg>;
export const ArrowUpIcon = (p: IP) => <svg {...ib(p)}><path d="M12 19V5M6 11l6-6 6 6" /></svg>;
export const ArrowDownIcon = (p: IP) => <svg {...ib(p)}><path d="M12 5v14M6 13l6 6 6-6" /></svg>;
export const BranchIcon = (p: IP) => <svg {...ib(p)}><circle cx="6" cy="5" r="2" /><circle cx="6" cy="19" r="2" /><circle cx="18" cy="7" r="2" /><path d="M6 7v10M18 9a6 6 0 0 1-6 6H8" /></svg>;
export const MusicIcon = (p: IP) => <svg {...ib(p)}><path d="M9 18V5l12-2v13" /><circle cx="6" cy="18" r="3" /><circle cx="18" cy="16" r="3" /></svg>;
export const SearchGlyph = (p: IP) => <svg {...ib(p)}><circle cx="11" cy="11" r="7" /><path d="m20 20-3.5-3.5" /></svg>;

/* ── Layout helpers ─────────────────────────────────────── */

export function WTitle({ children, right }: { children: ReactNode; right?: ReactNode }) {
  return (
    <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8, marginBottom: 8 }}>
      <span className="eyebrow">{children}</span>
      {right}
    </div>
  );
}

export function WEmpty({ children }: { children: ReactNode }) {
  return (
    <div style={{ flex: 1, display: "flex", alignItems: "center", justifyContent: "center", textAlign: "center", fontSize: 12, color: "rgba(255,255,255,0.45)", padding: 8, lineHeight: 1.45 }}>
      {children}
    </div>
  );
}

export function IconButton({ onClick, children, title, big }: { onClick: () => void; children: ReactNode; title?: string; big?: boolean }) {
  return (
    <button data-nodrag title={title} onClick={e => { e.stopPropagation(); onClick(); }} className="w-iconbtn" data-big={big ? "true" : undefined}>
      {children}
    </button>
  );
}
