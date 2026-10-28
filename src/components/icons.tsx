/**
 * Inline SVG icon set — Phosphor/Radix-inspired, single stroke weight.
 * All icons inherit `currentColor`; size via the `s` prop (default 16).
 * No emojis anywhere in the app — these replace them.
 */
import { useEffect, useState, type SVGProps } from "react";
import type { SourceId } from "../types";
import { invoke } from "../lib/tauri";

type IconProps = SVGProps<SVGSVGElement> & { s?: number };

function base({ s = 16, ...rest }: IconProps) {
  return {
    width: s, height: s, viewBox: "0 0 24 24",
    fill: "none", stroke: "currentColor",
    strokeWidth: 1.75, strokeLinecap: "round" as const, strokeLinejoin: "round" as const,
    ...rest,
  };
}

/* ── System ───────────────────────────────────────────────── */

export const SearchIcon = (p: IconProps) => (
  <svg {...base(p)}><circle cx="11" cy="11" r="7" /><path d="m20 20-3.5-3.5" /></svg>
);

export const SettingsIcon = (p: IconProps) => (
  <svg {...base(p)}>
    <circle cx="12" cy="12" r="3" />
    <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1Z" />
  </svg>
);

export const CloseIcon = (p: IconProps) => (
  <svg {...base(p)}><path d="M18 6 6 18M6 6l12 12" /></svg>
);

export const ReturnIcon = (p: IconProps) => (
  <svg {...base(p)}><path d="M9 10 4 15l5 5" /><path d="M20 4v7a4 4 0 0 1-4 4H4" /></svg>
);

export const ArrowUpDown = (p: IconProps) => (
  <svg {...base(p)}><path d="m7 15 5 5 5-5M7 9l5-5 5 5" /></svg>
);

export const CheckIcon = (p: IconProps) => (
  <svg {...base(p)}><path d="M20 6 9 17l-5-5" /></svg>
);

export const ChevronRight = (p: IconProps) => (
  <svg {...base(p)}><path d="m9 18 6-6-6-6" /></svg>
);

export const ExternalIcon = (p: IconProps) => (
  <svg {...base(p)}><path d="M15 3h6v6" /><path d="M10 14 21 3" /><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" /></svg>
);

/* ── Source-type icons ────────────────────────────────────── */

const FileIcon = (p: IconProps) => (
  <svg {...base(p)}><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" /><path d="M14 2v6h6" /></svg>
);

const TerminalIcon = (p: IconProps) => (
  <svg {...base(p)}><path d="m4 17 6-6-6-6" /><path d="M12 19h8" /></svg>
);

const GlobeIcon = (p: IconProps) => (
  <svg {...base(p)}><circle cx="12" cy="12" r="9" /><path d="M3 12h18" /><path d="M12 3a14 14 0 0 1 0 18 14 14 0 0 1 0-18Z" /></svg>
);

const GitIcon = (p: IconProps) => (
  <svg {...base(p)}><circle cx="6" cy="6" r="2.5" /><circle cx="6" cy="18" r="2.5" /><circle cx="18" cy="8" r="2.5" /><path d="M6 8.5v7" /><path d="M18 10.5a6 6 0 0 1-6 6h-2.5" /></svg>
);

const ClipboardIcon = (p: IconProps) => (
  <svg {...base(p)}><rect x="8" y="3" width="8" height="4" rx="1" /><path d="M16 5h2a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h2" /></svg>
);

const GitHubIcon = (p: IconProps) => (
  <svg {...base(p)}><path d="M9 19c-4.3 1.4-4.3-2.5-6-3m12 5v-3.5c0-1 .1-1.4-.5-2 2.8-.3 5.5-1.4 5.5-6a4.6 4.6 0 0 0-1.3-3.2 4.2 4.2 0 0 0-.1-3.2s-1.1-.3-3.5 1.3a12 12 0 0 0-6.2 0C6.5 2.8 5.4 3.1 5.4 3.1a4.2 4.2 0 0 0-.1 3.2A4.6 4.6 0 0 0 4 9.5c0 4.6 2.7 5.7 5.5 6-.6.6-.6 1.2-.5 2V21" /></svg>
);

const MailIcon = (p: IconProps) => (
  <svg {...base(p)}><rect x="3" y="5" width="18" height="14" rx="2" /><path d="m3 7 9 6 9-6" /></svg>
);

const ChatIcon = (p: IconProps) => (
  <svg {...base(p)}><path d="M21 11.5a8.5 8.5 0 0 1-12.3 7.6L3 21l1.9-5.7A8.5 8.5 0 1 1 21 11.5Z" /></svg>
);

const CubeIcon = (p: IconProps) => (
  <svg {...base(p)}><path d="M21 7.5 12 3 3 7.5v9L12 21l9-4.5z" /><path d="M3 7.5 12 12l9-4.5M12 12v9" /></svg>
);

const CalendarIcon = (p: IconProps) => (
  <svg {...base(p)}><rect x="3" y="4" width="18" height="17" rx="2" /><path d="M3 9h18M8 2v4M16 2v4" /></svg>
);

const ImageIcon = (p: IconProps) => (
  <svg {...base(p)}><rect x="3" y="3" width="18" height="18" rx="2" /><circle cx="9" cy="9" r="2" /><path d="m21 15-5-5L5 21" /></svg>
);

const NoteIcon = (p: IconProps) => (
  <svg {...base(p)}><path d="M4 4h16v12l-4 4H4z" /><path d="M16 20v-4h4" /><path d="M8 9h8M8 13h5" /></svg>
);

const AppsIcon = (p: IconProps) => (
  <svg {...base(p)}><rect x="3" y="3" width="7" height="7" rx="1.5" /><rect x="14" y="3" width="7" height="7" rx="1.5" /><rect x="3" y="14" width="7" height="7" rx="1.5" /><rect x="14" y="14" width="7" height="7" rx="1.5" /></svg>
);

const CommandIcon = (p: IconProps) => (
  <svg {...base(p)}><rect x="4" y="4" width="16" height="16" rx="3" /><path d="m8 9 3 3-3 3" /><path d="M13 15h3" /></svg>
);

const CalcIcon = (p: IconProps) => (
  <svg {...base(p)}><rect x="5" y="3" width="14" height="18" rx="2" /><path d="M9 7h6" /><path d="M8 12h.01M12 12h.01M16 12h.01M8 16h.01M12 16h.01M16 16h.01" /></svg>
);

const SparkleIcon = (p: IconProps) => (
  <svg {...base(p)}><path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z" /><path d="M19 15l.7 1.8L21.5 18l-1.8.7L19 21l-.7-1.8L16.5 18l1.8-.5z" /></svg>
);

export { CommandIcon, CalcIcon, SparkleIcon, AppsIcon };

/* ── Source registry ──────────────────────────────────────── */

export interface SourceMeta {
  label: string;
  Icon:  (p: IconProps) => JSX.Element;
  /** subtle tinted bg + accent for the icon tile */
  tint:  string;
  fg:    string;
}

export const SOURCE_META: Record<SourceId, SourceMeta> = {
  files:       { label: "File",       Icon: FileIcon,      tint: "rgba(255,255,255,0.09)", fg: "rgba(255,255,255,0.88)" },
  shell:       { label: "Command",    Icon: TerminalIcon,  tint: "rgba(255,255,255,0.09)", fg: "rgba(255,255,255,0.88)" },
  browser:     { label: "Browser",    Icon: GlobeIcon,     tint: "rgba(255,255,255,0.09)", fg: "rgba(255,255,255,0.88)" },
  git:         { label: "Commit",     Icon: GitIcon,       tint: "rgba(255,255,255,0.09)", fg: "rgba(255,255,255,0.88)" },
  clipboard:   { label: "Clipboard",  Icon: ClipboardIcon, tint: "rgba(255,255,255,0.09)", fg: "rgba(255,255,255,0.88)" },
  github:      { label: "GitHub",     Icon: GitHubIcon,    tint: "rgba(255,255,255,0.09)", fg: "rgba(255,255,255,0.88)" },
  gmail:       { label: "Email",      Icon: MailIcon,      tint: "rgba(255,255,255,0.09)", fg: "rgba(255,255,255,0.88)" },
  slack:       { label: "Slack",      Icon: ChatIcon,      tint: "rgba(255,255,255,0.09)", fg: "rgba(255,255,255,0.88)" },
  docker:      { label: "Docker",     Icon: CubeIcon,      tint: "rgba(255,255,255,0.09)", fg: "rgba(255,255,255,0.88)" },
  calendar:    { label: "Calendar",   Icon: CalendarIcon,  tint: "rgba(255,255,255,0.09)", fg: "rgba(255,255,255,0.88)" },
  screenshots: { label: "Screenshot", Icon: ImageIcon,     tint: "rgba(255,255,255,0.09)", fg: "rgba(255,255,255,0.88)" },
  notes:       { label: "Note",       Icon: NoteIcon,      tint: "rgba(255,255,255,0.09)", fg: "rgba(255,255,255,0.88)" },
  obsidian:    { label: "Obsidian",   Icon: NoteIcon,      tint: "rgba(255,255,255,0.09)", fg: "rgba(255,255,255,0.88)" },
  notion:      { label: "Notion",     Icon: NoteIcon,      tint: "rgba(255,255,255,0.09)", fg: "rgba(255,255,255,0.88)" },
  apps:        { label: "Application",Icon: AppsIcon,      tint: "rgba(255,255,255,0.09)", fg: "rgba(255,255,255,0.88)" },
  commands:    { label: "Command",    Icon: CommandIcon,   tint: "rgba(255,255,255,0.09)", fg: "rgba(255,255,255,0.88)" },
  calc:        { label: "Calculator", Icon: CalcIcon,      tint: "rgba(255,255,255,0.09)", fg: "rgba(255,255,255,0.88)" },
  ai:          { label: "Cortex AI",  Icon: SparkleIcon,   tint: "rgba(255,255,255,0.16)",  fg: "rgba(var(--accent-rgb),0.95)" },
};

/** Tinted rounded tile holding a source icon. */
export function SourceTile({ pluginId, size = 30 }: { pluginId: SourceId; size?: number }) {
  const m = SOURCE_META[pluginId] ?? SOURCE_META.files;
  return (
    <div style={{
      width: size, height: size, borderRadius: 7, flexShrink: 0,
      background: `linear-gradient(180deg, rgba(255,255,255,0.08), transparent), ${m.tint}`,
      border: "1px solid rgba(255,255,255,0.08)",
      boxShadow: "inset 0 1px 0 rgba(255,255,255,0.14)",
      display: "flex", alignItems: "center", justifyContent: "center",
      color: m.fg,
    }}>
      <m.Icon s={Math.round(size * 0.52)} />
    </div>
  );
}

/* ── Real macOS app icon (cached) ─────────────────────────── */

const iconCache = new Map<string, string | null>();

/**
 * Renders an application's real macOS icon (fetched once via `get_app_icon`,
 * cached module-wide). Falls back to the generic apps tile while loading or
 * when extraction fails (e.g. apps using asset-catalog icons).
 */
export function AppIcon({ path, size = 30 }: { path?: string; size?: number }) {
  // Initialise from cache for THIS path (so a reused instance with a new path
  // never shows the previous app's icon).
  const [src, setSrc] = useState<string | null>(() => (path ? iconCache.get(path) ?? null : null));

  useEffect(() => {
    let alive = true;
    if (!path) { setSrc(null); return; }
    const cached = iconCache.get(path);
    if (cached !== undefined) { setSrc(cached); return; } // undefined = not fetched yet
    setSrc(null); // reset while fetching the new path
    invoke<string | null>("get_app_icon", { path })
      .then((data) => { iconCache.set(path, data ?? null); if (alive) setSrc(data ?? null); })
      .catch(() => { iconCache.set(path, null); if (alive) setSrc(null); });
    return () => { alive = false; };
  }, [path]);

  if (src) {
    return <img src={src} width={size} height={size} alt="" style={{ borderRadius: 7, flexShrink: 0, objectFit: "contain" }} />;
  }
  return <SourceTile pluginId="apps" size={size} />;
}

/* ── Cortex logo mark — animated neuron node ──────────────── */

export function CortexMark({ s = 22, active = true }: { s?: number; active?: boolean }) {
  return (
    <svg width={s} height={s} viewBox="0 0 32 32" fill="none" aria-label="Cortex">
      {/* outer hex */}
      <path
        d="M16 3.5 26.5 9.5v13L16 28.5 5.5 22.5v-13z"
        stroke="rgba(255,255,255,0.22)" strokeWidth="1.4"
      />
      {/* node links */}
      <g stroke="rgba(255,255,255,0.30)" strokeWidth="1.1">
        <path d="M16 16 10 10M16 16 22 10M16 16 10 22M16 16 22 22" />
      </g>
      {/* satellite nodes */}
      <g fill="rgba(255,255,255,0.40)">
        <circle cx="10" cy="10" r="1.5" /><circle cx="22" cy="10" r="1.5" />
        <circle cx="10" cy="22" r="1.5" /><circle cx="22" cy="22" r="1.5" />
      </g>
      {/* core */}
      <circle cx="16" cy="16" r="2.6" fill="rgba(255,255,255,0.92)" />
      {active && (
        <circle cx="16" cy="16" r="2.6" fill="none" stroke="rgba(255,255,255,0.6)" strokeWidth="1">
          <animate attributeName="r" values="2.6;7;2.6" dur="2.4s" repeatCount="indefinite" />
          <animate attributeName="opacity" values="0.6;0;0.6" dur="2.4s" repeatCount="indefinite" />
        </circle>
      )}
    </svg>
  );
}
