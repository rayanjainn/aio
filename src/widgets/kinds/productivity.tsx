import { useEffect, useRef, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import type { WidgetProps } from "../types";
import { usePoll } from "../../hooks/usePoll";
import { invoke } from "../../lib/tauri";
import { relative } from "../format";
import { CheckIcon, PlusIcon, WEmpty, WTitle } from "../ui";
import { AppIcon } from "../../components/icons";

/* ── Notes ──────────────────────────────────────────────── */

export function NotesWidget({ config, setConfig, preview }: WidgetProps) {
  const [text, setText] = useState<string>(config.text ?? "");
  const timer = useRef<ReturnType<typeof setTimeout>>();
  useEffect(() => { setText(config.text ?? ""); }, [config.text]);
  const onChange = (v: string) => {
    setText(v);
    clearTimeout(timer.current);
    timer.current = setTimeout(() => setConfig({ text: v }), 500);
  };
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      <WTitle>{config.title || "Notes"}</WTitle>
      <textarea data-nodrag value={text} readOnly={preview} onChange={e => onChange(e.target.value)} spellCheck={false}
        placeholder="Jot something down…" className="w-textarea" />
    </div>
  );
}

/* ── To-dos ─────────────────────────────────────────────── */

type Todo = { id: string; text: string; done: boolean };

export function TodosWidget({ size, config, setConfig, preview }: WidgetProps) {
  const items: Todo[] = config.items ?? [];
  const [draft, setDraft] = useState("");
  const save = (next: Todo[]) => setConfig({ items: next });
  const add = () => {
    const t = draft.trim();
    if (!t) return;
    save([...items, { id: Math.random().toString(36).slice(2, 9), text: t, done: false }]);
    setDraft("");
  };
  const open = items.filter(i => !i.done).length;
  const visible = [...items.filter(i => !i.done), ...items.filter(i => i.done)].slice(0, size === "l" ? 12 : size === "m" ? 4 : 3);
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      <WTitle right={<span className="w-faint tnum" style={{ fontSize: 11 }}>{open} left</span>}>{config.title || "To-dos"}</WTitle>
      <div style={{ flex: 1, overflow: "hidden", display: "flex", flexDirection: "column", gap: 2 }}>
        <AnimatePresence initial={false}>
          {visible.map(t => (
            <motion.div key={t.id} layout initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, x: 20 }}
              transition={{ type: "spring", stiffness: 420, damping: 32 }} className="w-todo">
              <button data-nodrag className="w-check" data-done={t.done} disabled={preview}
                onClick={() => save(items.map(i => i.id === t.id ? { ...i, done: !i.done } : i))}>
                {t.done && <CheckIcon s={11} strokeWidth={3} />}
              </button>
              <span style={{ flex: 1, minWidth: 0, fontSize: 12.5, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis",
                opacity: t.done ? 0.4 : 0.92, textDecoration: t.done ? "line-through" : "none" }}>{t.text}</span>
              {t.done && !preview && (
                <button data-nodrag className="w-x" onClick={() => save(items.filter(i => i.id !== t.id))} title="Remove">×</button>
              )}
            </motion.div>
          ))}
        </AnimatePresence>
        {items.length === 0 && <div className="w-faint" style={{ fontSize: 12 }}>Nothing to do 🎉</div>}
      </div>
      {!preview && (
        <div style={{ display: "flex", gap: 6, marginTop: 6 }}>
          <input data-nodrag value={draft} onChange={e => setDraft(e.target.value)} onKeyDown={e => e.key === "Enter" && add()}
            placeholder="Add a to-do" className="w-input" />
          <button data-nodrag className="w-iconbtn" onClick={add} title="Add"><PlusIcon s={14} /></button>
        </div>
      )}
    </div>
  );
}

/* ── App launcher ───────────────────────────────────────── */

type App = { name: string; path: string };
const DEFAULT_APPS: App[] = [
  { name: "Safari", path: "/Applications/Safari.app" },
  { name: "Mail", path: "/System/Applications/Mail.app" },
  { name: "Notes", path: "/System/Applications/Notes.app" },
  { name: "Terminal", path: "/System/Applications/Utilities/Terminal.app" },
  { name: "Music", path: "/System/Applications/Music.app" },
  { name: "Calendar", path: "/System/Applications/Calendar.app" },
  { name: "Finder", path: "/System/Library/CoreServices/Finder.app" },
  { name: "System Settings", path: "/System/Applications/System Settings.app" },
];

export function LauncherWidget({ size, config }: WidgetProps) {
  const apps: App[] = config.apps?.length ? config.apps : DEFAULT_APPS;
  const n = size === "s" ? 4 : size === "m" ? 8 : 16;
  const cols = size === "s" ? 2 : 4;
  return (
    <div style={{ display: "grid", gridTemplateColumns: `repeat(${cols}, 1fr)`, gap: size === "s" ? 10 : 12, height: "100%", alignContent: "center" }}>
      {apps.slice(0, n).map(a => (
        <motion.button key={a.path} data-nodrag title={a.name} whileHover={{ scale: 1.1, y: -2 }} whileTap={{ scale: 0.9 }}
          transition={{ type: "spring", stiffness: 500, damping: 22 }}
          onClick={() => invoke("launch_path", { path: a.path }).catch(() => {})} className="w-app">
          <AppIcon path={a.path} size={size === "s" ? 46 : 44} />
          {size !== "s" && <span style={{ fontSize: 10.5, opacity: 0.75, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", maxWidth: 70 }}>{a.name}</span>}
        </motion.button>
      ))}
    </div>
  );
}

/* ── Clipboard ──────────────────────────────────────────── */

type Clip = { id: string; preview: string; content: string; sourceApp: string; ts: number };

export function ClipboardWidget({ size }: WidgetProps) {
  const { data } = usePoll<Clip[]>("get_clipboard_history", { limit: 12 }, 3000);
  const [copied, setCopied] = useState<string | null>(null);
  const clips = (data ?? []).slice(0, size === "l" ? 9 : size === "m" ? 3 : 2);
  const copy = async (c: Clip) => {
    try { await navigator.clipboard.writeText(c.content); setCopied(c.id); setTimeout(() => setCopied(null), 1200); } catch { /* denied */ }
  };
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      <WTitle>Clipboard</WTitle>
      {clips.length === 0 ? <WEmpty>Copy something to see it here</WEmpty> : (
        <div style={{ display: "flex", flexDirection: "column", gap: 4, overflow: "hidden" }}>
          {clips.map(c => (
            <button key={c.id} data-nodrag onClick={() => copy(c)} className="w-listbtn">
              <span style={{ flex: 1, minWidth: 0, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", fontSize: 12 }} className={/^[\w$./~-]+$/.test(c.preview) ? "mono" : ""}>
                {c.preview}
              </span>
              <span className="w-faint" style={{ fontSize: 10, flexShrink: 0 }}>{copied === c.id ? "Copied" : relative(c.ts)}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
