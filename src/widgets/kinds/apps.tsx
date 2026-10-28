/**
 * Widgets for apps that ship no widget of their own: any app (status +
 * controls), browser tabs, recent files / Downloads, editor projects, running
 * apps and terminal history.
 */
import { useEffect, useRef, useState } from "react";
import type { WidgetProps } from "../types";
import { usePoll } from "../../hooks/usePoll";
import { invoke } from "../../lib/tauri";
import { bytes, relative } from "../format";
import { Sparkline, WEmpty, WTitle } from "../ui";
import { AppIcon } from "../../components/icons";

/* ── Any app ────────────────────────────────────────────── */

type AppStatus = { running: boolean; cpu: number; memBytes: number; processes: number };

export function AppWidget({ size, config }: WidgetProps) {
  const app: { name: string; path: string } | undefined = config.app;
  const { data: st } = usePoll<AppStatus>("app_status", { path: app?.path ?? "" }, 2500, [app?.path]);
  const hist = useRef<number[]>([]);
  const [, bump] = useState(0);
  useEffect(() => {
    if (st?.running) { hist.current = [...hist.current, st.cpu].slice(-40); bump(x => x + 1); }
  }, [st]);
  if (!app) return <WEmpty>Pick an app in widget settings — any app, even ones without widgets</WEmpty>;
  const act = (action: string) => invoke("app_action", { path: app.path, action }).catch(() => {});
  const status = st?.running ? `${st.cpu.toFixed(st.cpu < 10 ? 1 : 0)}% CPU · ${bytes(st.memBytes)}` : "Not running";
  const buttons = (
    <div style={{ display: "flex", gap: 6 }}>
      <button data-nodrag className="w-chip" onClick={() => act("open")}>{st?.running ? "Show" : "Open"}</button>
      {st?.running && <button data-nodrag className="w-chip" onClick={() => act("hide")}>Hide</button>}
      {st?.running && <button data-nodrag className="w-chip" onClick={() => act("quit")}>Quit</button>}
    </div>
  );
  if (size === "s") return (
    <div style={{ display: "flex", flexDirection: "column", justifyContent: "space-between", height: "100%" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>
        <button data-nodrag className="w-appicon" onClick={() => act("open")}><AppIcon path={app.path} size={58} /></button>
        <span className={st?.running ? "w-live on" : "w-live"} />
      </div>
      <div>
        <div style={{ fontSize: 14, fontWeight: 650, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{app.name}</div>
        <div className="w-sub tnum" style={{ fontSize: 11.5 }}>{status}</div>
      </div>
    </div>
  );
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%", gap: 12 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
        <button data-nodrag className="w-appicon" onClick={() => act("open")}><AppIcon path={app.path} size={64} /></button>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 17, fontWeight: 650, letterSpacing: "-0.02em" }}>{app.name}</div>
          <div className="w-sub tnum">{status}{st?.running && st.processes > 1 ? ` · ${st.processes} processes` : ""}</div>
        </div>
        <span className={st?.running ? "w-live on" : "w-live"} />
      </div>
      {size === "l" && (
        <div style={{ flex: 1, display: "flex", flexDirection: "column", justifyContent: "flex-end" }}>
          <div className="w-faint" style={{ fontSize: 10.5, marginBottom: 4 }}>CPU · last 100s</div>
          <Sparkline data={hist.current} width={318} height={70} />
        </div>
      )}
      <div style={{ marginTop: "auto" }}>{buttons}</div>
    </div>
  );
}

/* ── Browser tabs ───────────────────────────────────────── */

type Tab = { browser: string; title: string; url: string };

function host(u: string) { try { return new URL(u).hostname.replace(/^www\./, ""); } catch { return u; } }

export function TabsWidget({ size }: WidgetProps) {
  const { data } = usePoll<Tab[]>("get_open_tabs", undefined, 8000);
  const tabs = data ?? [];
  const n = size === "l" ? 8 : size === "m" ? 3 : 2;
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      <WTitle right={<span className="w-faint tnum" style={{ fontSize: 11 }}>{tabs.length} open</span>}>Tabs</WTitle>
      {tabs.length === 0 ? <WEmpty>{data ? "No browser tabs open" : "Reading tabs…"}</WEmpty> : (
        <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
          {tabs.slice(0, n).map((t, i) => (
            <button key={i} data-nodrag className="w-listbtn" onClick={() => invoke("launch_path", { path: t.url }).catch(() => {})}>
              <span className="w-mono-badge">{host(t.url).charAt(0).toUpperCase()}</span>
              <span style={{ flex: 1, minWidth: 0 }}>
                <span style={{ display: "block", fontSize: 12.5, fontWeight: 550, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{t.title || host(t.url)}</span>
                {size !== "s" && <span className="w-faint" style={{ display: "block", fontSize: 10.5, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{host(t.url)} · {t.browser}</span>}
              </span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

/* ── Recent files / Downloads ───────────────────────────── */

type RFile = { name: string; path: string; modified: number; size: number; isDir: boolean };

function ext(name: string) { const m = name.match(/\.([a-z0-9]{1,5})$/i); return m ? m[1].toUpperCase() : ""; }

export function FilesWidget({ size, config, widget }: WidgetProps) {
  const folder: string = config.folder ?? (widget.kind === "downloads" ? "~/Downloads" : "");
  const n = size === "l" ? 8 : size === "m" ? 3 : 2;
  const { data } = usePoll<RFile[]>("recent_files", { folder: folder || null, limit: n }, 15_000, [folder, n]);
  const files = data ?? [];
  const title = config.title || (widget.kind === "downloads" ? "Downloads" : folder ? folder.split("/").pop() : "Recent Files");
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      <WTitle>{title}</WTitle>
      {files.length === 0 ? <WEmpty>{data ? "Nothing here yet" : "Looking…"}</WEmpty> : (
        <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
          {files.slice(0, n).map(f => (
            <button key={f.path} data-nodrag className="w-listbtn" onClick={() => invoke("launch_path", { path: f.path }).catch(() => {})}
              onContextMenu={e => { e.preventDefault(); invoke("reveal_in_finder", { path: f.path }).catch(() => {}); }} title="Click to open · right-click to reveal">
              {f.name.endsWith(".app") ? <AppIcon path={f.path} size={26} /> : <span className="w-file-badge">{f.isDir ? "▱" : ext(f.name) || "·"}</span>}
              <span style={{ flex: 1, minWidth: 0 }}>
                <span style={{ display: "block", fontSize: 12.5, fontWeight: 550, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{f.name}</span>
                {size !== "s" && <span className="w-faint tnum" style={{ display: "block", fontSize: 10.5 }}>{relative(f.modified)}{f.isDir ? "" : ` · ${bytes(f.size)}`}</span>}
              </span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

/* ── Code projects (VS Code / Cursor / Windsurf) ────────── */

type Project = { name: string; path: string; editor: string };

export function ProjectsWidget({ size }: WidgetProps) {
  const n = size === "l" ? 8 : size === "m" ? 4 : 2;
  const { data } = usePoll<Project[]>("editor_recent", { limit: n }, 30_000, [n]);
  const list = data ?? [];
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      <WTitle>Projects</WTitle>
      {list.length === 0 ? <WEmpty>{data ? "Open a folder in VS Code or Cursor" : "Loading…"}</WEmpty> : (
        <div style={{ display: size === "m" ? "grid" : "flex", gridTemplateColumns: "1fr 1fr", flexDirection: "column", gap: 2 }}>
          {list.map(p => (
            <button key={p.path} data-nodrag className="w-listbtn" title={`${p.path}\nOpen in ${p.editor}`}
              onClick={() => invoke("open_in", { app: p.editor, path: p.path }).catch(() => {})}>
              <span className="w-mono-badge">{p.name.charAt(0).toUpperCase()}</span>
              <span style={{ flex: 1, minWidth: 0 }}>
                <span style={{ display: "block", fontSize: 12.5, fontWeight: 600, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{p.name}</span>
                {size === "l" && <span className="w-faint" style={{ display: "block", fontSize: 10.5, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{p.path.replace(/^\/Users\/[^/]+/, "~")}</span>}
              </span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

/* ── Running apps ───────────────────────────────────────── */

export function RunningWidget({ size }: WidgetProps) {
  const { data } = usePoll<{ name: string; path: string }[]>("get_running_apps", undefined, 4000);
  const apps = data ?? [];
  const n = size === "s" ? 4 : size === "m" ? 8 : 16;
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      {size !== "s" && <WTitle right={<span className="w-faint tnum" style={{ fontSize: 11 }}>{apps.length} running</span>}>Running</WTitle>}
      <div style={{ flex: 1, display: "grid", gridTemplateColumns: `repeat(${size === "s" ? 2 : 4}, 1fr)`, gap: 10, alignContent: "center" }}>
        {apps.slice(0, n).map(a => (
          <button key={a.path} data-nodrag className="w-app" title={`${a.name} — click to switch, right-click to quit`}
            onClick={() => invoke("app_action", { path: a.path, action: "open" }).catch(() => {})}
            onContextMenu={e => { e.preventDefault(); invoke("app_action", { path: a.path, action: "quit" }).catch(() => {}); }}>
            <AppIcon path={a.path} size={size === "s" ? 46 : 42} />
          </button>
        ))}
      </div>
    </div>
  );
}

/* ── Terminal history ───────────────────────────────────── */

type SR = { id: string; title: string; timestamp?: string };

export function ShellWidget({ size }: WidgetProps) {
  const n = size === "l" ? 9 : size === "m" ? 3 : 2;
  const { data } = usePoll<{ results: SR[] }>("search", { req: { query: "", sourceFilter: ["shell"], limit: n } }, 10_000, [n]);
  const [copied, setCopied] = useState<string | null>(null);
  const list = data?.results ?? [];
  const copy = async (r: SR) => {
    try { await navigator.clipboard.writeText(r.title); setCopied(r.id); setTimeout(() => setCopied(null), 1100); } catch { /* denied */ }
  };
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      <WTitle>Terminal</WTitle>
      {list.length === 0 ? <WEmpty>{data ? "No shell history indexed yet" : "Loading…"}</WEmpty> : (
        <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
          {list.slice(0, n).map(r => (
            <button key={r.id} data-nodrag className="w-listbtn" onClick={() => copy(r)} title="Click to copy">
              <span className="mono" style={{ opacity: 0.45, fontSize: 11 }}>$</span>
              <span className="mono" style={{ flex: 1, minWidth: 0, fontSize: 11.5, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{r.title}</span>
              <span className="w-faint" style={{ fontSize: 10 }}>{copied === r.id ? "Copied" : ""}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
