import { useState, useEffect } from "react";
import { invoke } from "../lib/tauri";
import { SearchResult } from "../types";
import { AppIcon, SourceTile } from "./icons";

interface FileMeta { size: number; modified: number; isDir: boolean; kind: string; exists: boolean; }

interface PreviewPaneProps { result: SearchResult | null; query: string; }

function fmtBytes(b: number): string {
  if (b < 1024) return `${b} B`;
  if (b < 1024 ** 2) return `${(b / 1024).toFixed(1)} KB`;
  if (b < 1024 ** 3) return `${(b / 1024 ** 2).toFixed(1)} MB`;
  return `${(b / 1024 ** 3).toFixed(2)} GB`;
}
function fmtDate(unix: number): string {
  if (!unix) return "—";
  return new Date(unix * 1000).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

const C = {
  pane: { display: "flex", flexDirection: "column", height: "100%", overflow: "hidden" } as React.CSSProperties,
  label: { fontSize: 10.5, color: "rgba(255,255,255,0.32)", textTransform: "uppercase", letterSpacing: "0.07em" } as React.CSSProperties,
  value: { fontSize: 12.5, color: "rgba(255,255,255,0.78)" } as React.CSSProperties,
  code: { fontFamily: "var(--font-mono)", fontSize: 11.5, color: "rgba(255,255,255,0.72)", margin: 0, lineHeight: 1.6, whiteSpace: "pre-wrap", wordBreak: "break-word" } as React.CSSProperties,
};

function MetaRow({ k, v }: { k: string; v: React.ReactNode }) {
  return (
    <div style={{ display: "flex", justifyContent: "space-between", gap: 12, padding: "5px 0", borderBottom: "1px solid rgba(255,255,255,0.05)" }}>
      <span style={C.label}>{k}</span>
      <span style={{ ...C.value, textAlign: "right", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", maxWidth: "62%" }}>{v}</span>
    </div>
  );
}

export default function PreviewPane({ result, query }: PreviewPaneProps) {
  if (!result) return <Empty />;
  const t = result.pluginId;
  if (t === "apps")                  return <AppPreview r={result} />;
  if (t === "commands")              return <CommandPreview r={result} />;
  if (t === "git")                   return <GitPreview r={result} />;
  if (t === "clipboard")             return <ClipboardPreview r={result} />;
  if (t === "browser" || result.url) return <UrlPreview r={result} />;
  if (t === "gmail")                 return <EmailPreview r={result} />;
  if (result.path)                   return <FilePreview r={result} query={query} />;
  return <GenericPreview r={result} />;
}

function Empty() {
  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", height: "100%", gap: 10, opacity: 0.5 }}>
      <SourceTile pluginId="files" size={34} />
      <span style={{ fontSize: 12, color: "rgba(255,255,255,0.3)" }}>Select an item to preview</span>
    </div>
  );
}

/* ── File ── */
function FilePreview({ r, query }: { r: SearchResult; query: string }) {
  const [code, setCode] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [meta, setMeta] = useState<FileMeta | null>(null);

  useEffect(() => {
    if (!r.path) { setLoading(false); return; }
    setLoading(true); setCode(null); setMeta(null);
    invoke<FileMeta>("get_file_meta", { path: r.path }).then(setMeta).catch(() => {});
    invoke<string>("read_file_preview", { path: r.path, maxLines: 200 })
      .then(setCode).catch(() => setCode(null)).finally(() => setLoading(false));
  }, [r.path]);

  const parts = r.path?.split("/") ?? [];
  const filename = parts[parts.length - 1] ?? r.title;
  const dir = parts.slice(0, -1).join("/");
  const terms = query.trim().toLowerCase().split(/\s+/).filter(Boolean);

  return (
    <div style={C.pane}>
      <div style={{ padding: "16px 16px 12px", borderBottom: "1px solid rgba(255,255,255,0.07)", flexShrink: 0 }}>
        <div style={{ fontSize: 14, color: "rgba(255,255,255,0.92)", fontWeight: 600, fontFamily: "var(--font-mono)", marginBottom: 8, wordBreak: "break-all" }}>{filename}</div>
        <MetaRow k="Kind" v={meta?.kind ?? "—"} />
        <MetaRow k="Size" v={meta ? (meta.isDir ? "Folder" : fmtBytes(meta.size)) : "—"} />
        <MetaRow k="Modified" v={meta ? fmtDate(meta.modified) : "—"} />
        <MetaRow k="Where" v={<span style={{ fontFamily: "var(--font-mono)", fontSize: 11 }}>{dir}</span>} />
      </div>
      <div style={{ flex: 1, overflowY: "auto", padding: "10px 14px" }}>
        {loading && <Muted>Loading…</Muted>}
        {!loading && !code && <Muted>No text preview available</Muted>}
        {!loading && code && (
          <pre style={C.code}>
            {code.split("\n").map((line, i) => {
              const hit = terms.length > 0 && terms.some(tm => line.toLowerCase().includes(tm));
              return <span key={i} style={{ display: "block", background: hit ? "rgba(255,200,80,0.12)" : undefined, borderRadius: 3 }}>{line || " "}</span>;
            })}
          </pre>
        )}
      </div>
    </div>
  );
}

/* ── App ── */
function AppPreview({ r }: { r: SearchResult }) {
  return (
    <div style={{ ...C.pane, padding: 20, alignItems: "center", justifyContent: "center", gap: 16, textAlign: "center" }}>
      <AppIcon path={r.path} size={96} />
      <div>
        <div style={{ fontSize: 17, fontWeight: 600, color: "rgba(255,255,255,0.92)" }}>{r.title}</div>
        <div style={{ fontSize: 12, color: "rgba(255,255,255,0.4)", marginTop: 4 }}>Application</div>
      </div>
      <div style={{ width: "100%", marginTop: 4 }}>
        <MetaRow k="Path" v={<span style={{ fontFamily: "var(--font-mono)", fontSize: 11 }}>{r.path}</span>} />
        <MetaRow k="Action" v="Launch ↵" />
      </div>
    </div>
  );
}

/* ── Command ── */
function CommandPreview({ r }: { r: SearchResult }) {
  const run = (r.metadata as Record<string, unknown>)?.run as string | undefined;
  return (
    <div style={{ ...C.pane, padding: 20, gap: 14 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
        <SourceTile pluginId="commands" size={34} />
        <div>
          <div style={{ fontSize: 15, fontWeight: 600, color: "rgba(255,255,255,0.9)" }}>{r.title}</div>
          <div style={{ fontSize: 12, color: "rgba(255,255,255,0.4)" }}>System Command</div>
        </div>
      </div>
      {r.subtitle && <p style={{ fontSize: 13, color: "rgba(255,255,255,0.6)", lineHeight: 1.6, margin: 0 }}>{r.subtitle}</p>}
      {run && (
        <div>
          <div style={{ ...C.label, marginBottom: 6 }}>Runs</div>
          <pre style={{ ...C.code, background: "rgba(0,0,0,0.25)", border: "1px solid rgba(255,255,255,0.08)", borderRadius: 8, padding: 12 }}>$ {run}</pre>
        </div>
      )}
    </div>
  );
}

/* ── Clipboard ── */
function ClipboardPreview({ r }: { r: SearchResult }) {
  const text = r.content ?? r.title;
  return (
    <div style={C.pane}>
      <div style={{ padding: "14px 16px 10px", borderBottom: "1px solid rgba(255,255,255,0.07)" }}>
        <span style={C.label}>Clipboard · {text.length} chars</span>
      </div>
      <div style={{ flex: 1, overflowY: "auto", padding: 16 }}>
        <pre style={{ ...C.code, whiteSpace: "pre-wrap" }}>{text}</pre>
      </div>
    </div>
  );
}

/* ── Git ── */
function GitPreview({ r }: { r: SearchResult }) {
  const m = r.metadata as Record<string, unknown>;
  const sha = (m?.sha as string) ?? "";
  return (
    <div style={{ ...C.pane, padding: 20, gap: 14 }}>
      <div style={C.label}>Git Commit</div>
      {sha && <span style={{ fontFamily: "var(--font-mono)", fontSize: 13, color: "rgba(255,205,110,0.85)", background: "rgba(255,200,90,0.1)", padding: "3px 10px", borderRadius: 6, alignSelf: "flex-start" }}>{sha.slice(0, 10)}</span>}
      <div style={{ fontSize: 15, color: "rgba(255,255,255,0.9)", lineHeight: 1.5 }}>{r.title.replace(/^[a-f0-9]{7,10}\s*[—-]\s*/, "")}</div>
      {(m?.author as string) && <MetaRow k="Author" v={m.author as string} />}
      {r.timestamp && <MetaRow k="Date" v={new Date(r.timestamp).toLocaleString()} />}
    </div>
  );
}

/* ── URL ── */
function UrlPreview({ r }: { r: SearchResult }) {
  const domain = (() => { try { return new URL(r.url ?? "").hostname; } catch { return ""; } })();
  return (
    <div style={{ ...C.pane, padding: 20, gap: 14 }}>
      {domain && (
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <img src={`https://www.google.com/s2/favicons?domain=${domain}&sz=32`} width={20} height={20} style={{ borderRadius: 4 }} alt="" onError={e => ((e.target as HTMLImageElement).style.display = "none")} />
          <span style={{ fontSize: 12, color: "rgba(255,255,255,0.4)" }}>{domain}</span>
        </div>
      )}
      <div style={{ fontSize: 15, color: "rgba(255,255,255,0.9)", fontWeight: 600, lineHeight: 1.4 }}>{r.title}</div>
      {r.url && <div style={{ fontSize: 11, color: "rgba(255,205,110,0.8)", fontFamily: "var(--font-mono)", wordBreak: "break-all" }}>{r.url}</div>}
      {r.timestamp && <MetaRow k="Visited" v={new Date(r.timestamp).toLocaleString()} />}
    </div>
  );
}

/* ── Email ── */
function EmailPreview({ r }: { r: SearchResult }) {
  const m = r.metadata as Record<string, unknown>;
  return (
    <div style={{ ...C.pane, padding: 20, gap: 12 }}>
      <div style={C.label}>Email</div>
      <div style={{ fontSize: 16, fontWeight: 600, color: "rgba(255,255,255,0.9)", lineHeight: 1.4 }}>{(m?.subject as string) ?? r.title}</div>
      {(m?.from as string) && <MetaRow k="From" v={m.from as string} />}
      {r.subtitle && <p style={{ fontSize: 13, color: "rgba(255,255,255,0.6)", lineHeight: 1.7 }}>{r.subtitle}</p>}
    </div>
  );
}

/* ── Generic ── */
function GenericPreview({ r }: { r: SearchResult }) {
  return (
    <div style={{ ...C.pane, padding: 20, gap: 12 }}>
      <div style={{ fontSize: 15, color: "rgba(255,255,255,0.9)", fontWeight: 600 }}>{r.title}</div>
      {r.subtitle && <div style={{ fontSize: 13, color: "rgba(255,255,255,0.55)" }}>{r.subtitle}</div>}
      {r.content && <pre style={{ ...C.code, background: "rgba(0,0,0,0.2)", borderRadius: 8, padding: 12 }}>{r.content.slice(0, 1200)}</pre>}
    </div>
  );
}

function Muted({ children }: { children: React.ReactNode }) {
  return <p style={{ color: "rgba(255,255,255,0.3)", fontSize: 12, padding: 8 }}>{children}</p>;
}
