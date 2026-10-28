import { useState, useRef, useCallback, useEffect, useMemo } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { useSearch } from "../hooks/useSearch";
import { useStatus } from "../hooks/useStatus";
import { ToastStack } from "./ToastStack";
import PreviewPane from "./PreviewPane";
import { type SearchResult, type SourceId, type SearchResponse } from "../types";
import {
  SOURCE_META, SourceTile, AppIcon, CortexMark,
  SearchIcon, SettingsIcon, ReturnIcon, CloseIcon, CheckIcon, ChevronRight, ExternalIcon,
} from "./icons";
import { invoke, hideWindow, openExternal } from "../lib/tauri";
import { tryConvert } from "../lib/convert";
import { searchEmoji } from "../lib/emoji";
import { useGlassPointer } from "../hooks/useGlassPointer";

/* ── Utilities ──────────────────────────────────────────── */
function relativeTime(iso: string): string {
  const d = Date.now() - new Date(iso).getTime();
  const m = Math.floor(d / 60_000), h = Math.floor(d / 3_600_000), days = Math.floor(d / 86_400_000);
  if (m < 1) return "now"; if (m < 60) return `${m}m`; if (h < 24) return `${h}h`; return `${days}d`;
}
function formatBytes(b: number): string {
  if (b < 1e6) return `${(b / 1e3).toFixed(0)} KB`;
  if (b < 1e9) return `${(b / 1e6).toFixed(1)} MB`;
  return `${(b / 1e9).toFixed(2)} GB`;
}
function evalMath(input: string): number | null {
  const s = input.trim().replace(/×/g, "*").replace(/÷/g, "/");
  if (!/^[-+/*%^().\d\s]+$/.test(s)) return null;
  if (!/\d/.test(s) || !/[-+/*%^]/.test(s)) return null;
  try { const out = rpn(tokenize(s)); return Number.isFinite(out) ? out : null; } catch { return null; }
}
function tokenize(s: string): string[] { return s.match(/(\d+\.?\d*|\.\d+|[-+*/%^()])/g) ?? []; }
function rpn(tokens: string[]): number {
  const prec: Record<string, number> = { "+": 1, "-": 1, "*": 2, "/": 2, "%": 2, "^": 3 };
  const out: number[] = [], ops: string[] = [];
  const apply = (op: string) => { const b = out.pop()!, a = out.pop()!;
    out.push(op === "+" ? a + b : op === "-" ? a - b : op === "*" ? a * b : op === "/" ? a / b : op === "%" ? a % b : Math.pow(a, b)); };
  let prev: "num" | "op" | "(" | ")" | null = null;
  for (const t of tokens) {
    if (/^[\d.]/.test(t)) { out.push(parseFloat(t)); prev = "num"; }
    else if (t === "(") { ops.push(t); prev = "("; }
    else if (t === ")") { while (ops.length && ops[ops.length - 1] !== "(") apply(ops.pop()!); ops.pop(); prev = ")"; }
    else { if (t === "-" && (prev === null || prev === "op" || prev === "(")) out.push(0);
      while (ops.length && ops[ops.length - 1] !== "(" && (prec[ops[ops.length - 1]] > prec[t] || (prec[ops[ops.length - 1]] === prec[t] && t !== "^"))) apply(ops.pop()!);
      ops.push(t); prev = "op"; }
  }
  while (ops.length) apply(ops.pop()!);
  if (out.length !== 1) throw new Error("bad"); return out[0];
}
function fmtNum(n: number): string {
  if (Number.isInteger(n)) return n.toLocaleString();
  return parseFloat(n.toPrecision(10)).toLocaleString(undefined, { maximumFractionDigits: 8 });
}

/* ── Item model ─────────────────────────────────────────── */
type Kind = "calc" | "exec" | "ai" | "emoji" | "web" | "cmd" | "local" | "chatopen" | "clip" | "dir";
type Item = SearchResult & { _kind?: Kind; _emoji?: string; _cmd?: Cmd; _local?: boolean; _chatId?: string; _copy?: string; _snipId?: string };

/* Root capability commands (the "what can I do" list). */
interface Cmd { id: string; label: string; sub: string; icon: SourceId; mode: "files" | "source" | "ai" | "calc" | "emoji" | "chats" | "memory" | "clips" | "snippets" | "savesnip" | "winaction"; source?: SourceId; ask?: string; action?: string; }
const COMMANDS: Cmd[] = [
  { id: "ai",        label: "Ask AI",                 sub: "Chat with Cortex about your data", icon: "ai",  mode: "ai" },
  { id: "ghstats",   label: "GitHub Stats",           sub: "Your activity summary",      icon: "github",    mode: "ai", ask: "give me a summary of my github activity and stats" },
  { id: "rewind",    label: "Rewind",                 sub: "What you saw on screen earlier", icon: "screenshots", mode: "memory" },
  { id: "snippets",  label: "Snippets",               sub: "Saved reusable text — ↵ to copy", icon: "notes", mode: "snippets" },
  { id: "savesnip",  label: "Save Clipboard as Snippet", sub: "Store what's on your clipboard", icon: "clipboard", mode: "savesnip" },
  { id: "files",     label: "Search Files",          sub: "Find files across your Mac", icon: "files",     mode: "files" },
  { id: "browser",   label: "Search Browser History", sub: "Pages you've visited",       icon: "browser",   mode: "source", source: "browser" },
  { id: "github",    label: "Search GitHub",          sub: "Your repos, issues, PRs, commits", icon: "github", mode: "source", source: "github" },
  { id: "clipboard", label: "Clipboard History",      sub: "Paste anything you copied",  icon: "clipboard", mode: "clips" },
  { id: "git",       label: "Search Git Commits",     sub: "Across your repositories",   icon: "git",       mode: "source", source: "git" },
  { id: "sys",       label: "System Commands",        sub: "Lock, sleep, dark mode…",    icon: "commands",  mode: "source", source: "commands" },
  { id: "chats",     label: "Chat History",           sub: "Resume past AI conversations", icon: "ai",      mode: "chats" },
  { id: "calc",      label: "Calculator",             sub: "Math & unit conversions",    icon: "calc",      mode: "calc" },
  { id: "emoji",     label: "Emoji Picker",           sub: "Search & copy emoji",        icon: "calc",      mode: "emoji" },
  { id: "wl", label: "Window: Left Half",  sub: "Snap the active app left",     icon: "commands", mode: "winaction", action: "left" },
  { id: "wr", label: "Window: Right Half", sub: "Snap the active app right",    icon: "commands", mode: "winaction", action: "right" },
  { id: "wm", label: "Window: Maximize",   sub: "Fill the screen",             icon: "commands", mode: "winaction", action: "max" },
  { id: "wc", label: "Window: Center",     sub: "Center the active window",    icon: "commands", mode: "winaction", action: "center" },
  { id: "wf", label: "Window: Fullscreen", sub: "Toggle native fullscreen",   icon: "commands", mode: "winaction", action: "full" },
];

interface Scope { cmd: Cmd; }

const synthCalc = (expr: string, value: number): Item => ({ id: "s:calc", pluginId: "calc", title: fmtNum(value), subtitle: `${expr.trim()} =   ↵ copy`, score: 1, action: "copy", metadata: {}, _kind: "calc" } as Item);
const synthConv = (val: string, from: string): Item => ({ id: "s:conv", pluginId: "calc", title: val, subtitle: `${from}   ↵ copy`, score: 1, action: "copy", metadata: {}, _kind: "calc" } as Item);
const synthExec = (cmd: string): Item => ({ id: "s:exec", pluginId: "ai", title: `Run: ${cmd}`, subtitle: "Generate a shell command with AI  ·  ↵", score: 1, action: "run", metadata: {}, _kind: "exec" } as Item);
const synthAi = (q: string): Item => ({ id: "s:ai", pluginId: "ai", title: "Ask Cortex AI", subtitle: q ? `“${q}”  ·  ↵` : "Type a question, then ↵", content: q, score: 0, action: "preview", metadata: {}, _kind: "ai" } as Item);
const webItem = (id: string, title: string, url: string): Item => ({ id: `web:${id}`, pluginId: "browser", title, subtitle: "Open in browser  ·  ↵", url, score: 0, action: "open", metadata: {}, _kind: "web" } as Item);
const enc = encodeURIComponent;
const webSearches = (q: string): Item[] => [
  webItem("g", `Google “${q}”`, `https://www.google.com/search?q=${enc(q)}`),
  webItem("gh", `GitHub “${q}”`, `https://github.com/search?q=${enc(q)}&type=repositories`),
  webItem("yt", `YouTube “${q}”`, `https://www.youtube.com/results?search_query=${enc(q)}`),
];
const synthEmoji = (e: { c: string; name: string }): Item => ({ id: `s:emoji:${e.name}`, pluginId: "calc", title: e.name, subtitle: "↵ copy", score: 1, action: "copy", metadata: {}, _kind: "emoji", _emoji: e.c } as Item);
const cmdItem = (c: Cmd): Item => ({ id: `s:cmd:${c.id}`, pluginId: c.icon, title: c.label, subtitle: c.sub, score: 0.5, action: "open", metadata: {}, _kind: "cmd", _cmd: c } as Item);
const dirItem = (h: { name: string; path: string }): Item => ({ id: `dir:${h.path}`, pluginId: "files", title: h.name, subtitle: h.path, path: h.path, score: 1, action: "open", metadata: { is_dir: true }, _kind: "dir" } as Item);
const fileHitItem = (h: { name: string; path: string; is_dir?: boolean }): Item => h.is_dir
  ? dirItem(h)
  : ({ id: `file:${h.path}`, pluginId: "files", title: h.name, subtitle: h.path, path: h.path, score: 1, action: "open", metadata: {}, _local: true } as Item);
type Frame = { timestamp: number; appName: string; windowTitle: string; url: string | null; snippet: string };
const frameItem = (f: Frame): Item => ({
  id: `mem:${f.timestamp}:${Math.random().toString(36).slice(2, 6)}`,
  pluginId: f.url ? "browser" : "screenshots",
  title: (f.windowTitle && f.windowTitle.trim()) || f.appName || "Screen",
  subtitle: `${f.appName}${f.url ? " · " + f.url : ""}`,
  url: f.url ?? undefined, content: f.snippet,
  timestamp: new Date(f.timestamp * 1000).toISOString(),
  score: 1, action: f.url ? "open" : "preview", metadata: {}, _local: !!f.url,
} as Item);
const runningItem = (a: { name: string; path: string }): Item => ({ id: `apps:${a.path}`, pluginId: "apps", title: a.name, subtitle: "Running", path: a.path, score: 1, action: "open", metadata: {}, _local: true } as Item);
type Clip = { id: string; preview: string; content: string; sourceApp: string; ts: number };
const clipItem = (c: Clip): Item => ({ id: `clip:${c.id}`, pluginId: "clipboard", title: c.preview || "(empty)", subtitle: c.sourceApp ? `from ${c.sourceApp}` : "", content: c.content, score: 1, action: "copy", metadata: {}, _kind: "clip", _copy: c.content } as Item);
type Snip = { id: string; label: string; content: string; ts: number };
const snipItem = (s: Snip): Item => ({ id: `snip:${s.id}`, pluginId: "notes", title: s.label, subtitle: s.content.split(/\s+/).join(" ").slice(0, 80), content: s.content, score: 1, action: "copy", metadata: {}, _kind: "clip", _copy: s.content, _snipId: s.id } as Item);

function isPreviewable(it: Item | undefined): boolean {
  if (!it || (it._kind && it._kind !== undefined)) return it?._local ?? false;
  return ["files", "apps", "git", "clipboard", "browser", "gmail", "commands", "shell"].includes(it.pluginId)
    || !!it.path || !!it.url || !!it.content;
}

const SECTION_ORDER = ["apps", "commands", "files", "browser", "git", "clipboard", "gmail", "shell", "docker", "calendar", "slack", "github", "screenshots", "notes", "obsidian", "notion"] as const;
const SECTION_LABEL: Record<string, string> = {
  apps: "Applications", commands: "Commands", files: "Files", browser: "Browser History",
  git: "Git Commits", clipboard: "Clipboard", gmail: "Email", shell: "Shell History",
  docker: "Docker", calendar: "Calendar", slack: "Slack", github: "GitHub",
  screenshots: "Screenshots", notes: "Notes", obsidian: "Obsidian", notion: "Notion",
};
const SECTION_CAP: Record<string, number> = { apps: 6, commands: 5, files: 8 };
// Default "Ask AI" question shown at the top of each source scope (empty query).
const SCOPE_ASK: Record<string, string> = {
  github:   "summarize my recent GitHub activity — repos and commits this week",
  browser:  "what have I been browsing recently?",
  git:      "what have I been working on across my repos lately?",
  commands: "what system commands can you run?",
};
type Row = { header: string } | { item: Item; idx: number };

/* ── Kbd ────────────────────────────────────────────────── */
function Kbd({ children }: { children: React.ReactNode }) {
  return <kbd style={{ display: "inline-flex", alignItems: "center", justifyContent: "center", minWidth: 18, height: 18, padding: "0 5px", borderRadius: 4, background: "rgba(255,255,255,0.07)", border: "1px solid rgba(255,255,255,0.10)", fontSize: 11, color: "rgba(255,255,255,0.45)", fontFamily: "var(--font-mono)", lineHeight: 1 }}>{children}</kbd>;
}

/* ── Result row ─────────────────────────────────────────── */
function ResultRow({ item, selected, onHover, onClick, onActions }: { item: Item; selected: boolean; onHover: () => void; onClick: () => void; onActions: () => void }) {
  const meta = SOURCE_META[item.pluginId] ?? SOURCE_META.files;
  const sub = item.subtitle || item.url || item.path;
  const right = item._kind === "cmd" ? "Command" : item._kind === "dir" ? (item.title === ".." ? "Up" : "Folder") : item._local && item.subtitle === "Running" ? "Running" : meta.label;
  return (
    <div onMouseEnter={onHover} onClick={onClick} style={{ position: "relative", isolation: "isolate", display: "flex", alignItems: "center", gap: 10, padding: "0 8px 0 10px", height: 40, cursor: "pointer", margin: "0 8px", borderRadius: "var(--radius-row)" }}>
      {selected && <motion.div layoutId="palette-selection" className="liquid-pill" transition={{ type: "spring", stiffness: 520, damping: 38, mass: 0.7 }} />}
      {item._kind === "emoji"
        ? <div style={{ width: 24, height: 24, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 18, flexShrink: 0 }}>{item._emoji}</div>
        : item._kind === "dir"
        ? <div style={{ width: 24, height: 24, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 17, flexShrink: 0 }}>{item.title === ".." ? "↰" : "📁"}</div>
        : item.pluginId === "apps" ? <AppIcon path={item.path} size={24} /> : <SourceTile pluginId={item.pluginId} size={24} />}
      <div style={{ flex: 1, minWidth: 0, display: "flex", alignItems: "baseline", gap: 7 }}>
        <span style={{ fontSize: 12.5, fontWeight: 460, color: "rgba(255,255,255,0.92)", letterSpacing: "-0.01em", fontFamily: item.pluginId === "shell" ? "var(--font-mono)" : "var(--font-sans)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", flexShrink: 1 }}>{item.title}</span>
        {sub && <span style={{ fontSize: 11.5, color: "rgba(255,255,255,0.34)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", fontFamily: item.path && item.pluginId !== "apps" ? "var(--font-mono)" : "var(--font-sans)", flexShrink: 1, minWidth: 0 }}>{sub}</span>}
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 8, flexShrink: 0 }}>
        {item.timestamp && <span style={{ fontSize: 10.5, color: "rgba(255,255,255,0.24)", fontFamily: "var(--font-mono)" }}>{relativeTime(item.timestamp)}</span>}
        <span style={{ fontSize: 11, color: "rgba(255,255,255,0.34)" }}>{right}</span>
        {selected && (item._kind === "cmd" || item._kind === "chatopen" || isPreviewable(item))
          ? <button onClick={e => { e.stopPropagation(); item._kind === "cmd" ? onClick() : onActions(); }} title={item._kind === "cmd" ? "Enter ↵" : "Actions (→)"} style={{ background: "rgba(255,255,255,0.06)", border: "none", borderRadius: 5, color: "rgba(255,255,255,0.4)", cursor: "pointer", padding: "3px", display: "flex" }}><ChevronRight s={13} /></button>
          : null}
      </div>
    </div>
  );
}

function SectionHeader({ label }: { label: string }) {
  return <div style={{ padding: "8px 16px 3px", fontSize: 10, fontWeight: 600, color: "rgba(255,255,255,0.30)", letterSpacing: "0.06em", textTransform: "uppercase" }}>{label}</div>;
}

function OllamaBanner({ available, missingModels, onDismiss }: { available: boolean; missingModels: string[]; onDismiss: () => void }) {
  const msg = !available ? "Ollama not installed — AI search disabled." : `Missing model${missingModels.length > 1 ? "s" : ""}: ${missingModels.join(", ")}`;
  const hint = !available ? "Install Ollama to enable semantic search." : `ollama pull ${missingModels[0]}`;
  return (
    <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "6px 16px", gap: 12, background: "rgba(var(--accent-rgb),0.06)", borderBottom: "1px solid rgba(var(--accent-rgb),0.10)" }}>
      <span style={{ fontSize: 11.5, color: "rgba(var(--accent-rgb),0.72)" }}>{msg} <span style={{ opacity: 0.55, fontFamily: available ? "var(--font-mono)" : "inherit" }}>{hint}</span></span>
      <button onClick={onDismiss} style={{ background: "none", border: "none", cursor: "pointer", color: "rgba(255,255,255,0.25)", display: "flex", padding: 0 }}><CloseIcon s={13} /></button>
    </div>
  );
}

type ChatSource = { id: string; pluginId: SourceId; title: string; subtitle: string };
type ChatMsg = { role: "user" | "assistant"; content: string; sources?: ChatSource[] };

/* Minimal markdown: **bold**, `code`, and - / • bullet lines. */
function renderInline(text: string, keyBase: string): React.ReactNode[] {
  const parts = text.split(/(\*\*[^*]+\*\*|`[^`]+`)/g).filter(Boolean);
  return parts.map((p, i) => {
    if (p.startsWith("**") && p.endsWith("**")) return <b key={`${keyBase}-${i}`} style={{ color: "rgba(255,255,255,0.95)", fontWeight: 600 }}>{p.slice(2, -2)}</b>;
    if (p.startsWith("`") && p.endsWith("`")) return <code key={`${keyBase}-${i}`} style={{ fontFamily: "var(--font-mono)", fontSize: 12.5, background: "rgba(255,255,255,0.08)", padding: "1px 5px", borderRadius: 4 }}>{p.slice(1, -1)}</code>;
    return <span key={`${keyBase}-${i}`}>{p}</span>;
  });
}
function Markdown({ text }: { text: string }) {
  const lines = text.split("\n");
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 3 }}>
      {lines.map((ln, i) => {
        const m = ln.match(/^\s*[-*•]\s+(.*)/);
        if (m) return (
          <div key={i} style={{ display: "flex", gap: 7, paddingLeft: 4 }}>
            <span style={{ color: "rgba(var(--accent-rgb),0.7)" }}>•</span>
            <span style={{ flex: 1 }}>{renderInline(m[1], `b${i}`)}</span>
          </div>
        );
        if (!ln.trim()) return <div key={i} style={{ height: 4 }} />;
        return <div key={i}>{renderInline(ln, `l${i}`)}</div>;
      })}
    </div>
  );
}

function ChatView({ msgs, loading, input, onInput, onSend, onClose, onOpenSource }: {
  msgs: ChatMsg[]; loading: boolean; input: string;
  onInput: (v: string) => void; onSend: () => void; onClose: () => void; onOpenSource: (s: ChatSource) => void;
}) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const inRef = useRef<HTMLInputElement>(null);
  useEffect(() => { scrollRef.current?.scrollTo({ top: 1e9, behavior: "smooth" }); }, [msgs, loading]);
  useEffect(() => { inRef.current?.focus(); }, []);
  return (
    <div style={{ flex: 1, display: "flex", flexDirection: "column", minHeight: 0 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "10px 16px", borderBottom: "1px solid rgba(255,255,255,0.06)" }}>
        <SourceTile pluginId="ai" size={20} />
        <span style={{ fontSize: 12.5, color: "rgba(255,255,255,0.55)", flex: 1, fontWeight: 500 }}>Cortex AI</span>
        <button onClick={onClose} style={{ background: "rgba(255,255,255,0.07)", border: "none", borderRadius: 5, color: "rgba(255,255,255,0.4)", cursor: "pointer", padding: "2px 7px", fontSize: 11, fontFamily: "var(--font-mono)" }}>esc</button>
      </div>
      <div ref={scrollRef} style={{ flex: 1, overflowY: "auto", padding: "16px 18px", display: "flex", flexDirection: "column", gap: 14 }}>
        {msgs.length === 0 && !loading && (
          <div style={{ textAlign: "center", color: "rgba(255,255,255,0.28)", fontSize: 13, marginTop: 30 }}>
            Ask anything about your apps, files, history, repos…
          </div>
        )}
        {msgs.map((m, i) => (
          <div key={i} style={{ display: "flex", flexDirection: "column", alignItems: m.role === "user" ? "flex-end" : "flex-start", gap: 8, width: "100%" }}>
            <div style={{
              maxWidth: "84%", padding: "9px 13px", borderRadius: 12, fontSize: 13.5, lineHeight: 1.6,
              background: m.role === "user" ? "rgba(255,255,255,0.10)" : "rgba(var(--accent-rgb),0.08)",
              border: `1px solid ${m.role === "user" ? "rgba(255,255,255,0.10)" : "rgba(var(--accent-rgb),0.14)"}`,
              color: m.role === "user" ? "rgba(255,255,255,0.92)" : "rgba(255,235,200,0.94)",
              borderBottomRightRadius: m.role === "user" ? 3 : 12, borderBottomLeftRadius: m.role === "user" ? 12 : 3,
              whiteSpace: m.role === "user" ? "pre-wrap" : "normal",
            }}>
              {m.role === "assistant" ? <Markdown text={m.content} /> : m.content}
            </div>
            {m.role === "assistant" && m.sources && m.sources.length > 0 && (
              <div style={{ display: "flex", flexDirection: "column", gap: 4, width: "100%", maxWidth: "84%" }}>
                {m.sources.map(src => {
                  let domain = ""; try { if (src.subtitle.startsWith("http")) domain = new URL(src.subtitle).hostname.replace(/^www\./, ""); } catch {}
                  return (
                    <button key={src.id} onClick={() => onOpenSource(src)} title={src.subtitle}
                      style={{ display: "flex", alignItems: "center", gap: 10, padding: "7px 10px", borderRadius: 8, cursor: "pointer", textAlign: "left", width: "100%",
                        background: "rgba(255,255,255,0.045)", border: "1px solid rgba(255,255,255,0.08)" }}
                      onMouseEnter={e => (e.currentTarget.style.background = "rgba(255,255,255,0.09)")}
                      onMouseLeave={e => (e.currentTarget.style.background = "rgba(255,255,255,0.045)")}>
                      <SourceTile pluginId={src.pluginId} size={22} />
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontSize: 13, color: "rgba(255,255,255,0.88)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{src.title}</div>
                        {(domain || src.subtitle) && <div style={{ fontSize: 11, color: "rgba(255,255,255,0.35)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", fontFamily: "var(--font-mono)" }}>{domain || src.subtitle}</div>}
                      </div>
                      {src.subtitle.startsWith("http") ? <ExternalIcon s={13} /> : <ChevronRight s={13} />}
                    </button>
                  );
                })}
              </div>
            )}
          </div>
        ))}
        {loading && (
          <div style={{ display: "flex", gap: 4, alignItems: "center", color: "rgba(var(--accent-rgb),0.7)" }}>
            {[0, 1, 2].map(i => <span key={i} style={{ width: 5, height: 5, borderRadius: "50%", background: "rgba(var(--accent-rgb),0.7)", animation: `dot-bounce 1s ease-in-out ${i * 0.18}s infinite` }} />)}
          </div>
        )}
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "10px 14px", borderTop: "1px solid rgba(255,255,255,0.08)" }}>
        <SourceTile pluginId="ai" size={22} />
        <input ref={inRef} value={input} onChange={e => onInput(e.target.value)}
          onKeyDown={e => { if (e.key === "Enter" && !loading) { e.preventDefault(); onSend(); } }}
          placeholder="Reply to Cortex…" spellCheck={false}
          style={{ flex: 1, background: "transparent", border: "none", outline: "none", fontFamily: "var(--font-sans)", fontSize: 14.5, color: "rgba(255,255,255,0.92)", caretColor: "rgba(255,255,255,0.7)" }} />
        <button onClick={onSend} disabled={loading || !input.trim()} style={{ background: input.trim() && !loading ? "rgba(var(--accent-rgb),0.16)" : "rgba(255,255,255,0.05)", border: "1px solid rgba(var(--accent-rgb),0.2)", borderRadius: 7, color: "rgba(var(--accent-rgb),0.9)", cursor: input.trim() && !loading ? "pointer" : "default", padding: "5px 10px", display: "flex", alignItems: "center", gap: 5, fontSize: 12 }}>
          Send <ReturnIcon s={12} />
        </button>
      </div>
    </div>
  );
}

interface Action { id: string; label: string; hint?: string; run: () => void; }
function ActionsMenu({ actions, index, onHover, onRun, onClose }: { actions: Action[]; index: number; onHover: (i: number) => void; onRun: (a: Action) => void; onClose: () => void }) {
  return (
    <div style={{ position: "absolute", inset: 0, background: "rgba(10,10,14,0.55)", backdropFilter: "blur(6px)", display: "flex", justifyContent: "flex-end", zIndex: 20 }} onClick={onClose}>
      <div onClick={e => e.stopPropagation()} style={{ width: 300, height: "100%", background: "rgba(28,28,36,0.97)", borderLeft: "1px solid rgba(255,255,255,0.10)", padding: "10px 8px", display: "flex", flexDirection: "column" }}>
        <div style={{ fontSize: 11, fontWeight: 600, color: "rgba(255,255,255,0.3)", textTransform: "uppercase", letterSpacing: "0.06em", padding: "6px 10px 8px" }}>Actions</div>
        {actions.map((a, i) => (
          <button key={a.id} onMouseEnter={() => onHover(i)} onClick={() => onRun(a)} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10, width: "100%", textAlign: "left", padding: "9px 10px", borderRadius: 7, border: "none", cursor: "pointer", background: i === index ? "rgba(255,255,255,0.10)" : "transparent", color: "rgba(255,255,255,0.85)", fontSize: 13 }}>
            <span>{a.label}</span>{a.hint && <Kbd>{a.hint}</Kbd>}
          </button>
        ))}
      </div>
    </div>
  );
}

function EmptyState({ scope }: { scope: Scope | null }) {
  return (
    <div style={{ padding: "36px 24px", textAlign: "center" }}>
      <div style={{ fontSize: 13.5, color: "rgba(255,255,255,0.4)", marginBottom: 6 }}>
        {scope ? `Type to ${scope.cmd.label.toLowerCase()}` : "No results"}
      </div>
      <div style={{ fontSize: 12, color: "rgba(255,255,255,0.24)" }}>{scope?.cmd.sub ?? "Press ↵ to Ask AI"}</div>
    </div>
  );
}

function AnimatedCount({ value }: { value: number }) {
  const [shown, setShown] = useState(value); const prev = useRef(value);
  useEffect(() => {
    if (value === prev.current) return;
    const diff = value - prev.current, steps = Math.min(Math.abs(diff), 28);
    if (steps === 0) { setShown(value); prev.current = value; return; }
    const step = diff / steps; let i = 0, cur = prev.current;
    const id = setInterval(() => { i++; cur += step; setShown(Math.round(i < steps ? cur : value)); if (i >= steps) clearInterval(id); }, 22);
    prev.current = value; return () => clearInterval(id);
  }, [value]);
  return <>{shown.toLocaleString()}</>;
}

function Footer({ selected, indexedItems, storageBytes, recording, onOpenSettings, hasActions }: { selected: Item | null; indexedItems: number; storageBytes: number; recording: boolean; onOpenSettings?: () => void; hasActions: boolean }) {
  const label = selected?._kind === "calc" || selected?._kind === "emoji" || selected?._kind === "clip" ? "Copy"
    : selected?._kind === "exec" ? "Generate" : selected?._kind === "ai" ? "Ask"
    : selected?._kind === "web" ? "Search" : selected?._kind === "cmd" ? "Select"
    : selected ? selected.action[0].toUpperCase() + selected.action.slice(1) : null;
  return (
    <div style={{ borderTop: "1px solid rgba(255,255,255,0.07)", display: "flex", alignItems: "center", justifyContent: "space-between", padding: "0 12px 0 14px", height: 34, flexShrink: 0, background: "rgba(0,0,0,0.18)" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
        <CortexMark s={15} active={recording} />
        <span style={{ display: "flex", alignItems: "center", gap: 5, fontSize: 11, color: recording ? "rgba(110,225,150,0.62)" : "rgba(255,110,110,0.55)", fontFamily: "var(--font-mono)" }}>
          <span style={{ width: 5, height: 5, borderRadius: "50%", background: recording ? "rgba(110,225,150,0.85)" : "rgba(255,110,110,0.75)" }} />{recording ? "REC" : "PAUSED"}
        </span>
        {indexedItems > 0 && <span style={{ fontSize: 11, color: "rgba(255,255,255,0.22)", fontFamily: "var(--font-mono)" }}><AnimatedCount value={indexedItems} />{storageBytes > 0 && ` · ${formatBytes(storageBytes)}`}</span>}
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
        {label && <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, color: "rgba(255,255,255,0.45)" }}><span style={{ color: "rgba(255,255,255,0.60)", fontWeight: 500 }}>{label}</span><Kbd><ReturnIcon s={11} /></Kbd></div>}
        {hasActions && <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, color: "rgba(255,255,255,0.4)" }}>Actions<Kbd>→</Kbd></div>}
        <div style={{ width: 1, height: 16, background: "rgba(255,255,255,0.08)" }} />
        <button onClick={onOpenSettings} title="Settings (⌘,)" style={{ display: "flex", alignItems: "center", gap: 5, background: "transparent", border: "none", cursor: "pointer", color: "rgba(255,255,255,0.42)", fontSize: 12, padding: "4px 4px" }}
          onMouseEnter={e => (e.currentTarget.style.color = "rgba(255,255,255,0.75)")} onMouseLeave={e => (e.currentTarget.style.color = "rgba(255,255,255,0.42)")}>
          <SettingsIcon s={14} /> Settings
        </button>
      </div>
    </div>
  );
}

/* ── Main ───────────────────────────────────────────────── */
interface CommandPaletteProps {
  onOpenSettings?: () => void;
  onExecPlan?: (plan: { command: string; explanation: string; is_destructive: boolean }) => void;
  onOpenOnboarding?: () => void;
}

export function CommandPalette({ onOpenSettings, onExecPlan, onOpenOnboarding: _onb }: CommandPaletteProps = {}) {
  const { query, setQuery, response, loading, toasts, dismissToast, execute, ollamaHealth } = useSearch();
  const { status: liveStatus } = useStatus(5_000);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [ollamaDismissed, setOllamaDismissed] = useState(false);
  const [copied, setCopied] = useState(false);
  const [chat, setChat] = useState<{ id: string; msgs: ChatMsg[]; loading: boolean } | null>(null);
  const [chatInput, setChatInput] = useState("");
  const [chatList, setChatList] = useState<{ id: string; title: string; updated: number }[]>([]);
  const [actionsIndex, setActionsIndex] = useState(0);
  const [actionsOpen, setActionsOpen] = useState(false);
  const [scope, setScope] = useState<Scope | null>(null);
  const [fileHits, setFileHits] = useState<Item[]>([]);
  const [running, setRunning] = useState<Item[]>([]);
  const [memHits, setMemHits] = useState<Item[]>([]);
  const [clips, setClips] = useState<Item[]>([]);
  const [snips, setSnips] = useState<Item[]>([]);
  const [srcHits, setSrcHits] = useState<Item[]>([]);
  const [filesPath, setFilesPath] = useState<string | null>(null); // null = home
  const [dirEntries, setDirEntries] = useState<Item[]>([]);
  const [flash, setFlash] = useState<string | null>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  useGlassPointer(rootRef);
  const inputRef = useRef<HTMLInputElement>(null);
  const spotRef = useRef<ReturnType<typeof setTimeout>>();
  const srcRef = useRef<ReturnType<typeof setTimeout>>();

  const q = query.trim();
  const isExec = q.startsWith(">");
  const isAsk = q.startsWith("?");
  const isEmoji = q.startsWith(":");
  const backend = response?.results ?? [];

  // Running apps for the default screen.
  useEffect(() => {
    invoke<{ name: string; path: string }[]>("get_running_apps")
      .then(r => setRunning(r.map(runningItem))).catch(() => {});
  }, []);


  // Whole-home file search (Spotlight) — in Files scope, and also in the root
  // view so a filename you type surfaces real files from anywhere in ~.
  useEffect(() => {
    const filesScope = scope?.cmd.mode === "files";
    const rootSearch = !scope && !!q && !isExec && !isAsk && !isEmoji;
    if (!filesScope && !rootSearch) { setFileHits([]); return; }
    clearTimeout(spotRef.current);
    if (!q) { setFileHits([]); return; }
    spotRef.current = setTimeout(() => {
      invoke<{ name: string; path: string }[]>("spotlight_search", { query: q, limit: filesScope ? 30 : 6 })
        .then(hits => setFileHits(hits.map(fileHitItem))).catch(() => setFileHits([]));
    }, 130);
  }, [scope, q, isExec, isAsk, isEmoji]);

  const enterScope = useCallback((c: Cmd) => {
    setScope({ cmd: c }); setQuery("");
    if (c.mode === "files") setFilesPath(null); // start at home
    if (c.mode === "chats") invoke<{ id: string; title: string; updated: number }[]>("list_chats").then(setChatList).catch(() => {});
    if (c.mode === "memory") invoke<Frame[]>("memory_timeline", { hours: 12 }).then(fs => setMemHits(fs.map(frameItem))).catch(() => {});
    if (c.mode === "clips") invoke<Clip[]>("get_clipboard_history", { limit: 80 }).then(cs => setClips(cs.map(clipItem))).catch(() => {});
    if (c.mode === "snippets") invoke<Snip[]>("snippet_list").then(ss => setSnips(ss.map(snipItem))).catch(() => {});
  }, [setQuery]);
  const showFlash = useCallback((m: string) => { setFlash(m); setTimeout(() => setFlash(null), 1600); }, []);
  const saveClipSnippet = useCallback(async () => {
    try {
      const text = await navigator.clipboard.readText();
      if (!text.trim()) { showFlash("Clipboard empty"); return; }
      await invoke("snippet_add", { label: "", content: text });
      showFlash("Snippet saved");
    } catch { showFlash("Save failed"); }
  }, [showFlash]);
  const exitScope = useCallback(() => { setScope(null); setQuery(""); }, [setQuery]);

  // Files scope: when the search box is empty, browse the folder tree like
  // Finder (folders first). filesPath null = home; drilling sets it.
  useEffect(() => {
    if (scope?.cmd.mode !== "files") { setDirEntries([]); return; }
    if (q) { setDirEntries([]); return; } // typing → spotlight effect handles it
    invoke<{ name: string; path: string; is_dir?: boolean }[]>("list_dir", { path: filesPath })
      .then(es => setDirEntries(es.map(fileHitItem))).catch(() => setDirEntries([]));
  }, [scope, q, filesPath]);

  // Source scopes (GitHub / Browser History / Git / Commands): browse ALL items
  // on entry (empty query), then live-search as you type. Scoped to the one
  // source via sourceFilter so the backend returns recent items even for "".
  useEffect(() => {
    if (scope?.cmd.mode !== "source") { setSrcHits([]); return; }
    const src = scope.cmd.source!;
    clearTimeout(srcRef.current);
    const run = () => invoke<SearchResponse>("search", { req: { query: q, sourceFilter: [src], limit: 50 } })
      .then(res => setSrcHits((res.results ?? []) as unknown as Item[]))
      .catch(() => setSrcHits([]));
    if (!q) run(); else srcRef.current = setTimeout(run, 120);
    return () => clearTimeout(srcRef.current);
  }, [scope, q]);

  // Memory (Rewind) search-as-you-type within the scope.
  useEffect(() => {
    if (scope?.cmd.mode !== "memory") return;
    const t = setTimeout(() => {
      if (q.trim()) invoke<Frame[]>("search_memory", { query: q }).then(fs => setMemHits(fs.map(frameItem))).catch(() => {});
      else invoke<Frame[]>("memory_timeline", { hours: 12 }).then(fs => setMemHits(fs.map(frameItem))).catch(() => {});
    }, 140);
    return () => clearTimeout(t);
  }, [scope, q]);

  // Build sectioned rows + flat item list.
  const { rows, items } = useMemo(() => {
    const items: Item[] = []; const rows: Row[] = [];
    const seen = new Set<string>();
    const push = (it: Item) => { if (seen.has(it.id)) return; seen.add(it.id); rows.push({ item: it, idx: items.length }); items.push(it); };
    const header = (h: string) => rows.push({ header: h });

    // Global prefix shortcuts override scope.
    if (isExec) { const cmd = q.slice(1).trim(); if (cmd) { header("Execute"); push(synthExec(cmd)); } return { rows, items }; }
    if (isAsk)  { const qq = q.slice(1).trim() || q; header("Cortex AI"); push(synthAi(qq)); if (qq) webSearches(qq).forEach(push); return { rows, items }; }
    if (isEmoji){ const es = searchEmoji(q.slice(1)).map(synthEmoji); if (es.length) { header("Emoji"); es.forEach(push); } return { rows, items }; }

    // Scoped views.
    if (scope) {
      const m = scope.cmd.mode;
      if (m === "files") {
        if (q) { // typing → search files AND folders across the Mac
          if (fileHits.length) { header("Files & Folders"); fileHits.forEach(push); }
        } else { // empty → Finder-style browse of the current folder
          const here = filesPath ?? "Home";
          header(filesPath ? here.replace(/^\/Users\/[^/]+/, "~") : "Home  ·  ~");
          if (filesPath && filesPath !== "/") {
            const parent = filesPath.split("/").slice(0, -1).join("/") || "/";
            push({ id: `dir:${parent}`, pluginId: "files", title: "..", subtitle: "Up a folder", path: parent, score: 1, action: "open", metadata: { is_dir: true }, _kind: "dir" } as Item);
          }
          dirEntries.forEach(push);
        }
        return { rows, items };
      }
      if (m === "chats") {
        const cl = q ? chatList.filter(c => c.title.toLowerCase().includes(q.toLowerCase())) : chatList;
        if (cl.length) { header("Recent Chats"); cl.forEach(c => push({
          id: `chat:${c.id}`, pluginId: "ai", title: c.title || "Untitled chat",
          subtitle: `Resume · ${relativeTime(new Date(c.updated * 1000).toISOString())} ago`,
          score: 1, action: "open", metadata: {}, _kind: "chatopen", _chatId: c.id,
        } as Item)); }
        return { rows, items };
      }
      if (m === "memory") { if (memHits.length) { header(q ? "Memory" : "Recent Activity"); memHits.forEach(push); } return { rows, items }; }
      if (m === "clips") {
        const cs = q ? clips.filter(c => (c.content ?? "").toLowerCase().includes(q.toLowerCase())) : clips;
        if (cs.length) { header("Clipboard"); cs.forEach(push); }
        return { rows, items };
      }
      if (m === "snippets") {
        const ss = q ? snips.filter(s => (s.content ?? "").toLowerCase().includes(q.toLowerCase()) || s.title.toLowerCase().includes(q.toLowerCase())) : snips;
        if (ss.length) { header("Snippets"); ss.forEach(push); }
        else { /* empty -> EmptyState shows scope hint */ }
        return { rows, items };
      }
      if (m === "emoji") { const es = searchEmoji(q).map(synthEmoji); if (es.length) { header("Emoji"); es.forEach(push); } return { rows, items }; }
      if (m === "calc")  { const conv = tryConvert(q); const mm = conv ? null : evalMath(q); header("Calculator"); if (conv) push(synthConv(conv.value, conv.from)); else if (mm !== null) push(synthCalc(q, mm)); return { rows, items }; }
      if (m === "source") { // browser/git/github/commands — scoped browse + live search
        const src = scope.cmd.source!;
        if (srcHits.length) { header(`${SECTION_LABEL[src] ?? src}${q ? "" : " · recent"}`); srcHits.forEach(push); }
        // Ask-AI suggestion AFTER results, so ↵ opens the top item, not the AI.
        const aiQ = q.trim() ? `${q} (in my ${SECTION_LABEL[src] ?? src})` : (SCOPE_ASK[src] ?? `summarize my ${src}`);
        header("Ask Cortex AI"); push(synthAi(aiQ));
        return { rows, items };
      }
    }

    // ── Root view ──
    // calc/conv first
    const conv = tryConvert(q);
    if (conv) { header("Calculator"); push(synthConv(conv.value, conv.from)); }
    else { const mm = evalMath(q); if (mm !== null) { header("Calculator"); push(synthCalc(q, mm)); } }

    if (!q) {
      if (running.length) { header("Running"); running.slice(0, 6).forEach(push); }
    }

    // grouped backend results — but use Spotlight for the Files section
    // (whole-home, name match) instead of the limited Tantivy index.
    const groups = new Map<string, Item[]>();
    for (const r of backend as Item[]) { if (r.pluginId === "files") continue; const gg = groups.get(r.pluginId); if (gg) gg.push(r); else groups.set(r.pluginId, [r]); }
    const emit = (pid: string) => {
      if (pid === "files") { if (q && fileHits.length) { header("Files"); fileHits.slice(0, 6).forEach(push); } return; }
      const gg = groups.get(pid); if (!gg || !gg.length) return; header(SECTION_LABEL[pid] ?? pid); gg.slice(0, SECTION_CAP[pid] ?? 5).forEach(push);
    };
    SECTION_ORDER.forEach(emit);
    for (const pid of groups.keys()) if (!SECTION_ORDER.includes(pid as typeof SECTION_ORDER[number])) emit(pid);

    // Commands capability list (filtered by query)
    const cmds = COMMANDS.filter(c => !q || c.label.toLowerCase().includes(q.toLowerCase()) || c.sub.toLowerCase().includes(q.toLowerCase()));
    if (cmds.length) { header("Commands"); cmds.forEach(c => push(cmdItem(c))); }

    if (q.length > 0) { header("Cortex AI"); push(synthAi(q)); header("Web Search"); webSearches(q).forEach(push); }
    return { rows, items };
  }, [q, isExec, isAsk, isEmoji, backend, scope, fileHits, running, chatList, memHits, clips, snips, srcHits, dirEntries, filesPath]);

  const selected = items[selectedIndex] ?? null;
  const clampIndex = useCallback((n: number) => Math.max(0, Math.min(n, items.length - 1)), [items.length]);

  const copy = useCallback(async (text: string) => { try { await navigator.clipboard.writeText(text); setCopied(true); setTimeout(() => setCopied(false), 1200); } catch {} }, []);

  // Send a conversation turn → ask_ai_chat (RAG + history, persisted).
  const sendChat = useCallback(async (id: string, msgs: ChatMsg[]) => {
    setChat({ id, msgs, loading: true });
    try {
      // Tauri Channel = reliable token streaming (events weren't rendering).
      const { Channel } = await import("@tauri-apps/api/core");
      const ch = new Channel<string>();
      ch.onmessage = (delta) => {
        setChat((c) => {
          if (!c || c.id !== id) return c;
          const m = [...c.msgs];
          const last = m[m.length - 1];
          if (last && last.role === "assistant") m[m.length - 1] = { ...last, content: last.content + delta };
          else m.push({ role: "assistant", content: delta });
          return { ...c, msgs: m, loading: true };
        });
      };
      const reply = await invoke<{ answer: string; sources: ChatSource[] }>("ask_ai_chat", { threadId: id, messages: msgs, onChunk: ch });
      setChat({ id, msgs: [...msgs, { role: "assistant", content: reply.answer, sources: reply.sources }], loading: false });
    } catch (e) {
      const msg = e instanceof Error ? e.message : typeof e === "string" ? e : JSON.stringify(e);
      console.error("[cortex] ask_ai_chat", e);
      setChat({ id, msgs: [...msgs, { role: "assistant", content: msg || "AI request failed" }], loading: false });
    }
  }, []);
  const openSource = useCallback(async (src: ChatSource) => {
    try { await execute(src.id); hideWindow(); } catch (e) { console.error("[cortex] open source", e); }
  }, [execute]);
  const openChat = useCallback((question?: string) => {
    const id = (crypto as Crypto).randomUUID?.() ?? String(Date.now());
    if (question && question.trim()) { const msgs: ChatMsg[] = [{ role: "user", content: question.trim() }]; sendChat(id, msgs); }
    else setChat({ id, msgs: [], loading: false });
    setScope(null); setQuery("");
  }, [sendChat, setQuery]);
  const submitChat = useCallback(() => {
    if (!chat || !chatInput.trim() || chat.loading) return;
    const msgs: ChatMsg[] = [...chat.msgs, { role: "user", content: chatInput.trim() }];
    setChatInput(""); sendChat(chat.id, msgs);
  }, [chat, chatInput, sendChat]);
  const openSavedChat = useCallback(async (chatId: string) => {
    try { const msgs = await invoke<ChatMsg[]>("get_chat", { id: chatId }); setChat({ id: chatId, msgs, loading: false }); setScope(null); setQuery(""); }
    catch (e) { console.error("get_chat", e); }
  }, [setQuery]);

  const activate = useCallback(async (item: Item | undefined) => {
    if (!item) return;
    switch (item._kind) {
      case "cmd": if (item._cmd) {
        const c = item._cmd;
        if (c.mode === "ai") openChat(c.ask);
        else if (c.mode === "savesnip") saveClipSnippet();
        else if (c.mode === "winaction") { const a = c.action; setQuery(""); hideWindow(); setTimeout(() => invoke("window_action", { action: a }).catch(e => console.error(e)), 200); }
        else enterScope(c);
      } return;
      case "chatopen": if (item._chatId) openSavedChat(item._chatId); return;
      case "calc": copy(item.title); return;
      case "clip": copy(item._copy ?? item.content ?? item.title); return;
      case "emoji": if (item._emoji) copy(item._emoji); return;
      case "web": if (item.url) openExternal(item.url); setQuery(""); hideWindow(); return;
      case "exec":
        try { const plan = await invoke<{ command: string; explanation: string; is_destructive: boolean }>("plan_execution", { query: q.slice(1).trim(), sessionContext: "" }); onExecPlan?.(plan); } catch (e) { console.error(e); }
        return;
      case "ai": openChat(item.content ?? q); return;
      case "dir": if (item.path) { setFilesPath(item.path); setQuery(""); } return; // drill into folder
      default:
        // System/window commands act on the app behind Cortex — hide first so
        // it becomes frontmost, then run.
        if (item.pluginId === "commands") {
          setQuery(""); hideWindow();
          await new Promise(r => setTimeout(r, 170));
          await execute(item.id);
          return;
        }
        if (item._local && item.path) { openExternal(item.path); setQuery(""); hideWindow(); return; }
        await execute(item.id); setQuery(""); hideWindow(); return;
    }
  }, [q, execute, onExecPlan, openChat, openSavedChat, copy, setQuery, enterScope, saveClipSnippet]);

  const actions: Action[] = useMemo(() => {
    const it = selected;
    // Snippet rows: copy or delete.
    if (it?._snipId) {
      const sid = it._snipId;
      return [
        { id: "copy", label: "Copy Snippet", hint: "↵", run: () => activate(it) },
        { id: "del", label: "Delete Snippet", run: async () => {
            try { await invoke("snippet_delete", { id: sid });
                  const ss = await invoke<Snip[]>("snippet_list"); setSnips(ss.map(snipItem)); } catch (e) { console.error(e); } } },
      ];
    }
    // Chat-history rows: resume or delete.
    if (it?._kind === "chatopen" && it._chatId) {
      const cid = it._chatId;
      return [
        { id: "open", label: "Resume Chat", hint: "↵", run: () => activate(it) },
        { id: "del", label: "Delete Chat", run: async () => {
            try { await invoke("delete_chat", { id: cid });
                  const l = await invoke<{ id: string; title: string; updated: number }[]>("list_chats");
                  setChatList(l); } catch (e) { console.error(e); } } },
      ];
    }
    if (!it || !(it._local || isPreviewable(it)) || it._kind === "cmd") return [];
    const list: Action[] = [{ id: "open", label: it.pluginId === "apps" ? "Open Application" : "Open", hint: "↵", run: () => activate(it) }];
    if (it.path) {
      list.push({ id: "reveal", label: "Reveal in Finder", hint: "⌘↵", run: () => { invoke("reveal_in_finder", { path: it.path }); hideWindow(); } });
      list.push({ id: "ql", label: "Quick Look", hint: "⌥↵", run: () => invoke("quick_look", { path: it.path }) });
      list.push({ id: "cpath", label: "Copy Path", run: () => copy(it.path!) });
    }
    if (it.url) list.push({ id: "curl", label: "Copy URL", run: () => copy(it.url!) });
    list.push({ id: "cname", label: "Copy Name", run: () => copy(it.title) });
    return list;
  }, [selected, activate, copy]);
  const runAction = useCallback((a: Action) => { a.run(); setActionsOpen(false); }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (document.querySelector("[data-cortex-overlay]")) return;
      if (chat) { if (e.key === "Escape") { e.preventDefault(); setChat(null); } return; }
      if (actionsOpen) {
        if (e.key === "ArrowDown") { e.preventDefault(); setActionsIndex(i => Math.min(i + 1, actions.length - 1)); }
        else if (e.key === "ArrowUp") { e.preventDefault(); setActionsIndex(i => Math.max(i - 1, 0)); }
        else if (e.key === "Enter") { e.preventDefault(); const a = actions[actionsIndex]; if (a) runAction(a); }
        else if (e.key === "ArrowLeft" || e.key === "Escape") { e.preventDefault(); setActionsOpen(false); }
        return;
      }
      switch (e.key) {
        case "ArrowDown": case "Tab": e.preventDefault(); setSelectedIndex(i => clampIndex(i + 1)); break;
        case "ArrowUp": e.preventDefault(); setSelectedIndex(i => clampIndex(i - 1)); break;
        case "ArrowRight": if (actions.length && selected?._kind !== "cmd") { e.preventDefault(); setActionsIndex(0); setActionsOpen(true); } break;
        case "Backspace": if (!query && scope) { e.preventDefault(); exitScope(); } break;
        case "Enter":
          e.preventDefault();
          if (e.metaKey && selected?.path) { invoke("reveal_in_finder", { path: selected.path }); hideWindow(); }
          else if (e.altKey && selected?.path) { invoke("quick_look", { path: selected.path }); }
          else activate(selected ?? undefined);
          break;
        case "Escape": e.preventDefault(); if (scope) exitScope(); else if (query) setQuery(""); else hideWindow(); break;
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [chat, actionsOpen, actions, actionsIndex, selected, query, scope, clampIndex, activate, runAction, setQuery, exitScope]);

  useEffect(() => { setSelectedIndex(0); setActionsOpen(false); }, [q, scope]);
  useEffect(() => { const el = listRef.current?.querySelector(`[data-idx="${selectedIndex}"]`) as HTMLElement; el?.scrollIntoView({ block: "nearest" }); }, [selectedIndex]);
  useEffect(() => { inputRef.current?.focus(); }, []);

  const showOllama = !ollamaDismissed && ollamaHealth !== null && (!ollamaHealth.available || ollamaHealth.missingModels.length > 0);
  const showPreview = !chat && !actionsOpen && (selected?._local || isPreviewable(selected)) && selected?._kind !== "cmd";
  const placeholder = scope
    ? scope.cmd.mode === "files" ? "Search files across your Mac…"
      : scope.cmd.mode === "ai" ? "Ask Cortex AI…"
      : scope.cmd.mode === "calc" ? "12 * 7,  10 km to mi…"
      : scope.cmd.mode === "emoji" ? "Search emoji…"
      : scope.cmd.mode === "source" ? `Showing recent — type to filter, or ↵ to ask AI`
      : `Search ${scope.cmd.label.replace(/^Search /, "").toLowerCase()}…`
    : "Search apps, files, commands…   (> run · ? ask · : emoji)";

  return (
    <div ref={rootRef} className="glass-window">
      <AnimatePresence>
        {showOllama && <motion.div initial={{ height: 0, opacity: 0 }} animate={{ height: "auto", opacity: 1 }} exit={{ height: 0, opacity: 0 }}><OllamaBanner available={ollamaHealth!.available} missingModels={ollamaHealth!.missingModels} onDismiss={() => setOllamaDismissed(true)} /></motion.div>}
      </AnimatePresence>

      {/* Search bar */}
      <div data-tauri-drag-region style={{ display: "flex", alignItems: "center", gap: 10, padding: "0 16px", height: 50, flexShrink: 0, borderBottom: "1px solid rgba(255,255,255,0.08)" }}>
        <div style={{ width: 16, display: "flex", justifyContent: "center", flexShrink: 0, color: (isExec || isAsk || isEmoji) ? "rgba(var(--accent-rgb),0.7)" : "rgba(255,255,255,0.30)" }}>
          {loading ? <div style={{ display: "flex", gap: 2 }}>{[0, 1, 2].map(i => <span key={i} style={{ width: 3, height: 3, borderRadius: "50%", background: "rgba(255,255,255,0.45)", animation: `dot-bounce 1s ease-in-out ${i * 0.18}s infinite` }} />)}</div>
            : (isExec || isAsk || isEmoji) ? <span style={{ fontFamily: "var(--font-mono)", fontSize: 15 }}>{isExec ? ">" : isAsk ? "?" : ":"}</span> : <SearchIcon s={16} />}
        </div>
        {scope && (
          <button onClick={exitScope} style={{ display: "flex", alignItems: "center", gap: 6, flexShrink: 0, background: "rgba(255,255,255,0.08)", border: "1px solid rgba(255,255,255,0.12)", borderRadius: 7, padding: "4px 8px 4px 6px", cursor: "pointer" }}>
            <SourceTile pluginId={scope.cmd.icon} size={18} />
            <span style={{ fontSize: 12.5, color: "rgba(255,255,255,0.8)", fontWeight: 500 }}>{scope.cmd.label}</span>
            <CloseIcon s={11} />
          </button>
        )}
        <input ref={inputRef} value={query} onChange={e => setQuery(e.target.value)} placeholder={placeholder} spellCheck={false} autoComplete="off"
          style={{ flex: 1, background: "transparent", border: "none", outline: "none", fontFamily: "var(--font-sans)", fontSize: 15, fontWeight: 400, color: "rgba(255,255,255,0.92)", caretColor: "rgba(255,255,255,0.70)", letterSpacing: "-0.01em" }} />
        {(copied || flash) && <span style={{ fontSize: 12, color: "rgba(110,225,150,0.85)", display: "flex", alignItems: "center", gap: 4 }}><CheckIcon s={13} /> {flash || "Copied"}</span>}
        {query && <button onClick={() => setQuery("")} style={{ background: "rgba(255,255,255,0.07)", border: "none", borderRadius: 5, color: "rgba(255,255,255,0.40)", cursor: "pointer", padding: "3px 5px", display: "flex", alignItems: "center" }}><CloseIcon s={13} /></button>}
      </div>

      {/* Body */}
      <div style={{ flex: 1, display: "flex", minHeight: 0, position: "relative" }}>
        {chat ? <ChatView msgs={chat.msgs} loading={chat.loading} input={chatInput} onInput={setChatInput} onSend={submitChat} onClose={() => setChat(null)} onOpenSource={openSource} /> : (
          <>
            <div ref={listRef} style={{ flex: 1, overflowY: "auto", padding: "6px 0", minWidth: 0 }}>
              {items.length > 0
                ? rows.map((row, i) => "header" in row
                  ? <SectionHeader key={`h${i}`} label={row.header} />
                  : <div key={row.item.id} data-idx={row.idx}><ResultRow item={row.item} selected={row.idx === selectedIndex} onHover={() => setSelectedIndex(row.idx)} onClick={() => activate(row.item)} onActions={() => { setActionsIndex(0); setActionsOpen(true); }} /></div>)
                : <EmptyState scope={scope} />}
            </div>
            {showPreview && <div style={{ width: 330, flexShrink: 0, borderLeft: "1px solid rgba(255,255,255,0.07)", background: "rgba(255,255,255,0.015)" }}><PreviewPane result={selected} query={query} /></div>}
            {actionsOpen && <ActionsMenu actions={actions} index={actionsIndex} onHover={setActionsIndex} onRun={runAction} onClose={() => setActionsOpen(false)} />}
          </>
        )}
      </div>

      <Footer selected={selected} indexedItems={liveStatus.indexedItems} storageBytes={liveStatus.storageBytes} recording={liveStatus.recording} onOpenSettings={onOpenSettings} hasActions={actions.length > 0 && selected?._kind !== "cmd"} />

      <style>{`input::placeholder { color: rgba(255,255,255,0.24) !important; }`}</style>
      <ToastStack toasts={toasts} onDismiss={dismissToast} />
    </div>
  );
}
