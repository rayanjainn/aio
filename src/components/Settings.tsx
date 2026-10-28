import { useState, useEffect, useCallback } from "react";
import { invoke } from "../lib/tauri";
import {
  SourceTile, CheckIcon, CloseIcon, ExternalIcon,
  SettingsIcon, type SourceMeta, SOURCE_META,
} from "./icons";
import type { SourceId } from "../types";

/* ── Types ── */

interface Config {
  retentionDays: number;
  blockedApps: string[];
  rawStorage: boolean;
  compressRaw: boolean;
  githubToken: string;
  enabledPlugins: Record<string, boolean>;
  fileRoots: string[];
  quotaBytes: number;
  terminal: string;
}

interface DaemonStatus { storageBytes: number; indexedItems: number; recording: boolean; }
interface GoogleStatus { connected: boolean; email: string | null; expired: boolean; }
interface GithubStatus { connected: boolean; username: string | null; error: string | null; }

const DEFAULT_CONFIG: Config = {
  retentionDays: 30, blockedApps: [], rawStorage: false, compressRaw: false,
  githubToken: "", enabledPlugins: {
    files: true, shell: true, browser: true, git: true,
    github: true, docker: true, vscode: true, email: true,
    slack: true, clipboard: true,
  },
  fileRoots: [], quotaBytes: 5 * 1024 * 1024 * 1024, terminal: "Terminal",
};

type Section = "general" | "connections" | "sources" | "storage" | "about";
interface SettingsProps { onClose: () => void; }

/* ── Glass tokens ── */
const card: React.CSSProperties = {
  background: "rgba(255,255,255,0.045)",
  border: "1px solid rgba(255,255,255,0.08)",
  borderRadius: 10, padding: "16px 18px",
};
const input: React.CSSProperties = {
  flex: 1, padding: "8px 12px", borderRadius: 7,
  border: "1px solid rgba(255,255,255,0.12)", background: "rgba(255,255,255,0.05)",
  color: "rgba(255,255,255,0.88)", fontSize: 13, outline: "none",
};
const select: React.CSSProperties = {
  padding: "6px 10px", borderRadius: 7, border: "1px solid rgba(255,255,255,0.12)",
  background: "rgba(30,30,38,0.9)", color: "rgba(255,255,255,0.88)", fontSize: 13, cursor: "pointer",
};
const btn: React.CSSProperties = {
  padding: "7px 14px", borderRadius: 7, border: "1px solid rgba(255,255,255,0.14)",
  background: "rgba(255,255,255,0.06)", color: "rgba(255,255,255,0.66)", fontSize: 12,
  cursor: "pointer", whiteSpace: "nowrap", display: "inline-flex", alignItems: "center", gap: 6,
};
const btnDanger: React.CSSProperties = {
  ...btn, border: "1px solid rgba(255,100,100,0.32)",
  background: "rgba(255,100,100,0.10)", color: "rgba(255,125,125,0.85)",
};
const label: React.CSSProperties = {
  display: "block", fontSize: 11, fontWeight: 600, color: "rgba(255,255,255,0.30)",
  textTransform: "uppercase", letterSpacing: "0.06em", marginBottom: 10,
};
const h2: React.CSSProperties = {
  fontFamily: "var(--font-display)", fontSize: 17, color: "rgba(255,255,255,0.88)", margin: 0,
};

/* ── Connection card ── */
function ConnectionCard({ pluginId, name, description, connected, subtitle, error, onConnect, onDisconnect, loading, cta }: {
  pluginId: SourceId; name: string; description: string;
  connected: boolean; subtitle?: string | null; error?: string | null;
  onConnect: () => void; onDisconnect?: () => void; loading?: boolean; cta?: string;
}) {
  return (
    <div style={{ ...card, display: "flex", alignItems: "center", gap: 14,
      border: `1px solid ${connected ? "rgba(110,225,150,0.20)" : "rgba(255,255,255,0.08)"}` }}>
      <SourceTile pluginId={pluginId} size={34} />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 13.5, color: "rgba(255,255,255,0.85)", fontWeight: 500, marginBottom: 2 }}>{name}</div>
        <div style={{ fontSize: 11.5, color: connected ? "rgba(110,225,150,0.70)" : "rgba(255,255,255,0.35)" }}>
          {connected && subtitle ? subtitle : connected ? description : error || description}
        </div>
      </div>
      {connected ? (
        <div style={{ display: "flex", alignItems: "center", gap: 10, flexShrink: 0 }}>
          <span style={{ display: "flex", alignItems: "center", gap: 5, color: "rgba(110,225,150,0.80)" }}>
            <CheckIcon s={14} /><span style={{ fontSize: 11.5, fontFamily: "var(--font-mono)" }}>Connected</span>
          </span>
          {onDisconnect && <button onClick={onDisconnect} style={btnDanger}>Disconnect</button>}
        </div>
      ) : (
        <button onClick={onConnect} disabled={loading} style={{ ...btn, opacity: loading ? 0.6 : 1,
          border: "1px solid rgba(255,200,90,0.30)", color: "rgba(255,205,110,0.85)", background: "rgba(255,200,90,0.07)" }}>
          {loading ? "Connecting…" : (cta ?? "Connect")}
        </button>
      )}
    </div>
  );
}

/* ── Toggle ── */
function Toggle({ checked, onChange }: { checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <button onClick={() => onChange(!checked)} style={{
      width: 38, height: 21, borderRadius: 11, flexShrink: 0,
      background: checked ? "rgba(110,225,150,0.75)" : "rgba(255,255,255,0.13)",
      border: "none", cursor: "pointer", position: "relative", transition: "background 180ms",
    }}>
      <span style={{ position: "absolute", top: 2.5, left: checked ? 19.5 : 2.5,
        width: 16, height: 16, borderRadius: "50%",
        background: checked ? "rgba(12,14,16,0.95)" : "rgba(255,255,255,0.5)",
        transition: "left 180ms" }} />
    </button>
  );
}

function Row({ label: l, children }: { label: string; children: React.ReactNode }) {
  return (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
      <span style={{ fontSize: 13, color: "rgba(255,255,255,0.58)" }}>{l}</span>
      {children}
    </div>
  );
}

/* ── Section nav icon (small geometric SVG) ── */
function NavDot({ active }: { active: boolean }) {
  return <span style={{ width: 5, height: 5, borderRadius: "50%", flexShrink: 0,
    background: active ? "rgba(255,255,255,0.7)" : "rgba(255,255,255,0.2)" }} />;
}

/* ── Component ── */
export default function Settings({ onClose }: SettingsProps) {
  const [section, setSection] = useState<Section>("general");
  const [config, setConfig] = useState<Config>(DEFAULT_CONFIG);
  const [daemon, setDaemon] = useState<DaemonStatus | null>(null);
  const [newBlockedApp, setNewBlockedApp] = useState("");
  const [newRoot, setNewRoot] = useState("");
  const [toast, setToast] = useState<string | null>(null);
  const [confirmClear, setConfirmClear] = useState(false);
  const [recording, setRecording] = useState(true);

  const [google, setGoogle] = useState<GoogleStatus | null>(null);
  const [github, setGithub] = useState<GithubStatus | null>(null);
  const [googleLoading, setGoogleLoading] = useState(false);
  const [githubChecking, setGithubChecking] = useState(false);
  const [terminals, setTerminals] = useState<string[]>([]);

  useEffect(() => {
    invoke<string[]>("detect_terminals").then(setTerminals).catch(() => {});
    invoke<Config>("get_config").then(setConfig).catch(() => {});
    invoke<DaemonStatus>("get_daemon_status").then(s => { setDaemon(s); setRecording(s.recording); }).catch(() => {});
    invoke<GoogleStatus>("check_google_auth").then(setGoogle).catch(() => {});
    setGithubChecking(true);
    invoke<GithubStatus>("check_github_token").then(setGithub)
      .catch(() => setGithub({ connected: false, username: null, error: "check failed" }))
      .finally(() => setGithubChecking(false));
  }, []);

  const showToast = (m: string) => { setToast(m); setTimeout(() => setToast(null), 2000); };

  const save = useCallback(async (key: string, value: unknown) => {
    try { await invoke("set_config", { key, value }); showToast("Saved"); }
    catch { showToast("Save failed"); }
  }, []);

  const update = <K extends keyof Config>(k: K, v: Config[K]) => { setConfig(p => ({ ...p, [k]: v })); save(k, v); };

  const toggleRecording = async () => {
    const next = await invoke<boolean>("toggle_recording");
    setRecording(next); showToast(next ? "Recording resumed" : "Recording paused");
  };

  const clearCaptures = async () => {
    try { await invoke("clear_captures"); showToast("Captures cleared"); setConfirmClear(false); }
    catch { showToast("Clear failed"); }
  };

  const connectGoogle = async () => {
    setGoogleLoading(true);
    // Suppress click-away-hide while the OAuth browser tab steals focus.
    await invoke("set_autohide", { enabled: false }).catch(() => {});
    try {
      const s = await invoke<GoogleStatus>("connect_google");
      setGoogle(s);
      showToast(s.connected ? "Gmail connected" : "Connection failed");
    } catch (e) {
      showToast(e instanceof Error ? e.message : "Connection failed");
    } finally {
      setGoogleLoading(false);
      await invoke("set_autohide", { enabled: true }).catch(() => {});
    }
  };

  const disconnectGoogle = () => { setGoogle({ connected: false, email: null, expired: false }); showToast("Disconnected"); };

  const recheckGithub = async () => {
    setGithubChecking(true);
    try { setGithub(await invoke<GithubStatus>("check_github_token")); }
    catch { setGithub({ connected: false, username: null, error: "check failed" }); }
    finally { setGithubChecking(false); }
  };

  const fmt = (b: number) => b > 1e9 ? `${(b/1e9).toFixed(1)} GB` : b > 1e6 ? `${(b/1e6).toFixed(0)} MB` : `${(b/1e3).toFixed(0)} KB`;

  const SECTIONS: { id: Section; label: string }[] = [
    { id: "general",     label: "General" },
    { id: "connections", label: "Connections" },
    { id: "sources",     label: "Sources" },
    { id: "storage",     label: "Storage" },
    { id: "about",       label: "About" },
  ];
  const PLUGINS: SourceId[] = ["files","shell","browser","git","github","docker","gmail","slack","clipboard","calendar"];

  return (
    <div data-cortex-overlay style={{
      position: "fixed", inset: 0, zIndex: 1000,
      display: "flex", flexDirection: "column",
      background: "rgba(20,20,26,0.85)",
      backdropFilter: "blur(48px) saturate(190%)", WebkitBackdropFilter: "blur(48px) saturate(190%)",
      borderRadius: 12, overflow: "hidden",
      border: "1px solid rgba(255,255,255,0.10)",
      fontFamily: "var(--font-sans)",
    }} onKeyDown={e => e.key === "Escape" && onClose()}>

      {/* Title bar (draggable) */}
      <div data-tauri-drag-region style={{
        display: "flex", alignItems: "center", justifyContent: "space-between",
        height: 48, padding: "0 14px", flexShrink: 0,
        borderBottom: "1px solid rgba(255,255,255,0.08)",
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, color: "rgba(255,255,255,0.70)" }}>
          <SettingsIcon s={15} />
          <span style={{ fontFamily: "var(--font-display)", fontSize: 13, fontWeight: 600, letterSpacing: "0.04em" }}>SETTINGS</span>
        </div>
        <button onClick={onClose} style={{ ...btn, padding: "5px 7px" }}><CloseIcon s={14} /></button>
      </div>

      <div style={{ flex: 1, display: "flex", overflow: "hidden" }}>
        {/* Sidebar */}
        <div style={{ width: 168, flexShrink: 0, padding: "12px 8px",
          borderRight: "1px solid rgba(255,255,255,0.07)", background: "rgba(255,255,255,0.02)" }}>
          {SECTIONS.map(s => (
            <button key={s.id} onClick={() => setSection(s.id)} style={{
              display: "flex", alignItems: "center", gap: 10, width: "100%",
              padding: "8px 12px", marginBottom: 2, border: "none", borderRadius: 7, cursor: "pointer",
              background: section === s.id ? "rgba(255,255,255,0.08)" : "transparent",
              color: section === s.id ? "rgba(255,255,255,0.90)" : "rgba(255,255,255,0.45)",
              fontSize: 13, textAlign: "left", transition: "background 120ms",
            }}>
              <NavDot active={section === s.id} /> {s.label}
            </button>
          ))}
        </div>

        {/* Content */}
        <div style={{ flex: 1, overflowY: "auto", padding: "24px 26px" }}>

          {section === "general" && (
            <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>
              <h2 style={h2}>General</h2>
              <div style={card}><Row label="Screen recording">
                <button onClick={toggleRecording} style={{ ...btn,
                  border: `1px solid ${recording ? "rgba(110,225,150,0.30)" : "rgba(255,100,100,0.30)"}`,
                  background: recording ? "rgba(110,225,150,0.08)" : "rgba(255,100,100,0.08)",
                  color: recording ? "rgba(110,225,150,0.85)" : "rgba(255,110,110,0.85)" }}>
                  {recording ? "Recording" : "Paused"}
                </button>
              </Row></div>
              <div style={card}><Row label="Retention period">
                <select value={config.retentionDays} onChange={e => update("retentionDays", +e.target.value)} style={select}>
                  {[7,14,30,90].map(d => <option key={d} value={d}>{d} days</option>)}
                </select>
              </Row></div>
              <div style={card}><Row label="Terminal for commands">
                <select value={config.terminal} onChange={e => update("terminal", e.target.value)} style={select}>
                  {(terminals.length ? terminals : [config.terminal]).map(t => <option key={t} value={t}>{t}</option>)}
                </select>
              </Row></div>
              <div style={card}>
                <label style={label}>Blocked apps (never captured)</label>
                <div style={{ display: "flex", gap: 8, marginBottom: 10 }}>
                  <input value={newBlockedApp} onChange={e => setNewBlockedApp(e.target.value)}
                    onKeyDown={e => { if (e.key === "Enter" && newBlockedApp.trim()) { update("blockedApps", [...config.blockedApps, newBlockedApp.trim()]); setNewBlockedApp(""); } }}
                    placeholder="App name or bundle ID" style={input} />
                  <button onClick={() => { if (newBlockedApp.trim()) { update("blockedApps", [...config.blockedApps, newBlockedApp.trim()]); setNewBlockedApp(""); } }} style={btn}>Add</button>
                </div>
                <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
                  {config.blockedApps.map(a => (
                    <span key={a} style={{ display: "flex", alignItems: "center", gap: 6, padding: "3px 10px", borderRadius: 20,
                      background: "rgba(255,255,255,0.06)", color: "rgba(255,255,255,0.55)", fontSize: 12, border: "1px solid rgba(255,255,255,0.10)" }}>
                      {a}<button onClick={() => update("blockedApps", config.blockedApps.filter(x => x !== a))}
                        style={{ background: "none", border: "none", color: "rgba(255,255,255,0.35)", cursor: "pointer", display: "flex" }}><CloseIcon s={11} /></button>
                    </span>
                  ))}
                </div>
              </div>
              <div style={card}>
                <label style={label}>Clear all captures</label>
                <p style={{ color: "rgba(255,255,255,0.35)", fontSize: 12, margin: "0 0 12px" }}>
                  Permanently deletes screen captures and OCR data from disk.
                </p>
                {confirmClear ? (
                  <div style={{ display: "flex", gap: 8 }}>
                    <button onClick={clearCaptures} style={btnDanger}>Confirm delete</button>
                    <button onClick={() => setConfirmClear(false)} style={btn}>Cancel</button>
                  </div>
                ) : <button onClick={() => setConfirmClear(true)} style={btnDanger}>Clear captures</button>}
              </div>
            </div>
          )}

          {section === "connections" && (
            <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
              <h2 style={h2}>Connections</h2>
              <p style={{ fontSize: 12, color: "rgba(255,255,255,0.35)", lineHeight: 1.6, marginTop: -6 }}>
                Credentials stored locally in ~/.cortex/ — nothing leaves your machine.
              </p>
              <ConnectionCard pluginId="gmail" name="Gmail"
                description="Index emails, threads, and attachments"
                connected={google?.connected ?? false}
                subtitle={google?.email ? `${google.email}${google.expired ? " · token expired" : ""}` : null}
                onConnect={connectGoogle} onDisconnect={disconnectGoogle} loading={googleLoading} />
              <ConnectionCard pluginId="github" name="GitHub"
                description="PRs, issues, commits across your repos"
                connected={github?.connected ?? false}
                subtitle={github?.username ? `@${github.username}` : github?.error ?? null}
                onConnect={recheckGithub} loading={githubChecking} cta="Re-check" />
              <div style={card}>
                <label style={label}>GitHub token</label>
                <p style={{ fontSize: 11.5, color: "rgba(255,255,255,0.32)", marginBottom: 10, lineHeight: 1.6 }}>
                  Read from <code style={{ fontFamily: "var(--font-mono)", color: "rgba(255,205,110,0.7)" }}>~/.cortex/config.toml</code> under{" "}
                  <code style={{ fontFamily: "var(--font-mono)", color: "rgba(255,205,110,0.7)" }}>[github] token</code>.
                </p>
                <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
                  <div style={{ flex: 1, padding: "8px 12px", borderRadius: 7, border: "1px solid rgba(255,255,255,0.10)",
                    background: "rgba(255,255,255,0.04)", color: "rgba(255,255,255,0.32)", fontSize: 12, fontFamily: "var(--font-mono)" }}>
                    {github?.connected ? `Token valid · @${github.username}` : (github?.error ?? "Not configured")}
                  </div>
                  <button onClick={recheckGithub} disabled={githubChecking} style={btn}>{githubChecking ? "Checking…" : "Re-check"}</button>
                </div>
              </div>
            </div>
          )}

          {section === "sources" && (
            <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
              <h2 style={h2}>Sources</h2>
              <div style={card}>
                <label style={label}>Enabled plugins</label>
                <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
                  {PLUGINS.map(p => {
                    const m: SourceMeta = SOURCE_META[p];
                    return (
                      <div key={p} style={{ display: "flex", alignItems: "center", gap: 11, padding: "7px 8px", borderRadius: 7 }}>
                        <SourceTile pluginId={p} size={26} />
                        <span style={{ flex: 1, color: "rgba(255,255,255,0.74)", fontSize: 13 }}>{m.label}</span>
                        <Toggle checked={config.enabledPlugins[p] ?? true} onChange={v => update("enabledPlugins", { ...config.enabledPlugins, [p]: v })} />
                      </div>
                    );
                  })}
                </div>
              </div>
              <div style={card}>
                <label style={label}>File index roots</label>
                <div style={{ display: "flex", gap: 8, marginBottom: 8 }}>
                  <input value={newRoot} onChange={e => setNewRoot(e.target.value)}
                    onKeyDown={e => { if (e.key === "Enter" && newRoot.trim()) { update("fileRoots", [...config.fileRoots, newRoot.trim()]); setNewRoot(""); } }}
                    placeholder="/Users/you/Projects" style={input} />
                  <button onClick={() => { if (newRoot.trim()) { update("fileRoots", [...config.fileRoots, newRoot.trim()]); setNewRoot(""); } }} style={btn}>Add</button>
                </div>
                {config.fileRoots.map(r => (
                  <div key={r} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "6px 10px", borderRadius: 7,
                    background: "rgba(255,255,255,0.04)", marginBottom: 4, fontSize: 12, color: "rgba(255,255,255,0.55)", fontFamily: "var(--font-mono)", border: "1px solid rgba(255,255,255,0.06)" }}>
                    {r}<button onClick={() => update("fileRoots", config.fileRoots.filter(x => x !== r))} style={{ background: "none", border: "none", color: "rgba(255,255,255,0.30)", cursor: "pointer", display: "flex" }}><CloseIcon s={12} /></button>
                  </div>
                ))}
              </div>
            </div>
          )}

          {section === "storage" && (
            <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
              <h2 style={h2}>Storage</h2>
              {daemon && (
                <div style={card}>
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: 12, marginBottom: 10, color: "rgba(255,255,255,0.55)" }}>
                    <span>{fmt(daemon.storageBytes)} used</span><span>{fmt(config.quotaBytes)} quota</span>
                  </div>
                  <div style={{ height: 6, background: "rgba(255,255,255,0.08)", borderRadius: 3, overflow: "hidden" }}>
                    <div style={{ height: "100%", borderRadius: 3, width: `${Math.min(100, (daemon.storageBytes / config.quotaBytes) * 100)}%`,
                      background: daemon.storageBytes / config.quotaBytes > 0.85 ? "rgba(255,100,100,0.7)" : "rgba(110,225,150,0.7)", transition: "width 300ms" }} />
                  </div>
                </div>
              )}
              <div style={card}>
                <Row label="Keep raw JPEG after OCR"><Toggle checked={config.rawStorage} onChange={v => update("rawStorage", v)} /></Row>
                {config.rawStorage && <div style={{ marginTop: 14 }}><Row label="Compress with zstd"><Toggle checked={config.compressRaw} onChange={v => update("compressRaw", v)} /></Row></div>}
              </div>
              <div style={card}><Row label="Data folder">
                <button onClick={() => invoke("open_data_folder")} style={btn}><ExternalIcon s={13} /> Open ~/.cortex/</button>
              </Row></div>
            </div>
          )}

          {section === "about" && (
            <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
              <h2 style={h2}>About Cortex</h2>
              <div style={card}>
                {[["Version","0.1.0"],["Toggle palette","⌘K"],["Settings","⌘,"],["Pause capture","⌘⇧P"]].map(([k,v]) => (
                  <div key={k} style={{ display: "flex", justifyContent: "space-between", padding: "6px 0", fontSize: 13 }}>
                    <span style={{ color: "rgba(255,255,255,0.45)" }}>{k}</span>
                    <span style={{ color: "rgba(255,255,255,0.80)", fontFamily: "var(--font-mono)" }}>{v}</span>
                  </div>
                ))}
                {daemon && (
                  <div style={{ display: "flex", justifyContent: "space-between", padding: "6px 0", fontSize: 13, borderTop: "1px solid rgba(255,255,255,0.06)", marginTop: 4 }}>
                    <span style={{ color: "rgba(255,255,255,0.45)" }}>Items indexed</span>
                    <span style={{ color: "rgba(255,255,255,0.80)", fontFamily: "var(--font-mono)" }}>{daemon.indexedItems.toLocaleString()}</span>
                  </div>
                )}
              </div>
            </div>
          )}
        </div>
      </div>

      {toast && (
        <div style={{ position: "fixed", bottom: 20, right: 20, background: "rgba(28,28,38,0.95)",
          backdropFilter: "blur(20px)", border: "1px solid rgba(255,255,255,0.12)", borderRadius: 8,
          padding: "9px 16px", color: "rgba(255,255,255,0.85)", fontSize: 13, boxShadow: "0 8px 24px rgba(0,0,0,0.5)" }}>{toast}</div>
      )}
    </div>
  );
}
