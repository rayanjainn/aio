import { useState, useEffect, useCallback, useRef } from "react";
import { invoke, openExternal as open } from "../lib/tauri";
import { SourceTile, CortexMark, CheckIcon } from "./icons";

/* ────────────────────────────────────────────────────────────
   Types
──────────────────────────────────────────────────────────── */

interface OllamaStatus {
  available: boolean;
  models: string[];
  checking: boolean;
}

interface PermissionItem {
  id: string;
  label: string;
  description: string;
  deeplink: string;
  granted: boolean;
}

interface ConnectedSources {
  gmail: boolean;
  github: boolean;
  slack: boolean;
}

interface DaemonStatus {
  pluginCounts: Partial<Record<string, number>>;
  indexedItems: number;
  activePlugins: string[];
}

interface OnboardingProps {
  onComplete: () => void;
}

/* ────────────────────────────────────────────────────────────
   Constants
──────────────────────────────────────────────────────────── */

const PLUGINS = [
  "files", "shell", "browser", "git", "github",
  "docker", "vscode", "email", "slack", "clipboard",
] as const;

const PERMISSIONS: PermissionItem[] = [
  {
    id: "screen",
    label: "Screen Recording",
    description: "Required for OCR and visual memory capture",
    deeplink: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
    granted: false,
  },
  {
    id: "accessibility",
    label: "Accessibility",
    description: "Required to read active window titles and app context",
    deeplink: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
    granted: false,
  },
  {
    id: "notifications",
    label: "Notifications",
    description: "Required for sync alerts and indexing status",
    deeplink: "x-apple.systempreferences:com.apple.preference.notifications",
    granted: false,
  },
];

/* ────────────────────────────────────────────────────────────
   Shared sub-components
──────────────────────────────────────────────────────────── */

function Spinner() {
  return (
    <div style={{ display: "flex", gap: 3, alignItems: "center" }}>
      {[0, 1, 2].map((i) => (
        <span
          key={i}
          style={{
            width: 5,
            height: 5,
            borderRadius: "50%",
            background: "var(--amber)",
            display: "inline-block",
            animation: `dot-bounce 1.2s ease-in-out ${i * 0.2}s infinite`,
          }}
        />
      ))}
    </div>
  );
}

function StepDot({ active, done }: { active: boolean; done: boolean }) {
  return (
    <div
      style={{
        width: done ? 10 : active ? 10 : 8,
        height: done ? 10 : active ? 10 : 8,
        borderRadius: "50%",
        background: done ? "var(--green)" : active ? "var(--amber)" : "var(--surface-3)",
        border: done
          ? "1px solid rgba(74,222,128,0.4)"
          : active
          ? "1px solid rgba(232,164,48,0.6)"
          : "1px solid var(--border-hi)",
        boxShadow: active ? "0 0 8px var(--amber-pulse)" : "none",
        transition: "all 200ms",
        flexShrink: 0,
      }}
    />
  );
}

function AmberBtn({
  onClick,
  disabled,
  children,
  style,
}: {
  onClick: () => void;
  disabled?: boolean;
  children: React.ReactNode;
  style?: React.CSSProperties;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      style={{
        background: disabled ? "var(--surface-3)" : "var(--amber)",
        color: disabled ? "var(--text-3)" : "var(--text-inv)",
        border: "none",
        borderRadius: 6,
        padding: "9px 20px",
        fontFamily: "var(--font-sans)",
        fontWeight: 600,
        fontSize: 13,
        cursor: disabled ? "not-allowed" : "pointer",
        transition: "opacity 150ms, transform 100ms",
        letterSpacing: "0.01em",
        ...style,
      }}
      onMouseDown={(e) => { if (!disabled) (e.currentTarget as HTMLElement).style.transform = "scale(0.97)"; }}
      onMouseUp={(e) => { (e.currentTarget as HTMLElement).style.transform = "scale(1)"; }}
    >
      {children}
    </button>
  );
}

function GhostBtn({
  onClick,
  children,
  style,
}: {
  onClick: () => void;
  children: React.ReactNode;
  style?: React.CSSProperties;
}) {
  return (
    <button
      onClick={onClick}
      style={{
        background: "transparent",
        color: "var(--text-3)",
        border: "1px solid var(--border-hi)",
        borderRadius: 6,
        padding: "9px 20px",
        fontFamily: "var(--font-sans)",
        fontWeight: 500,
        fontSize: 13,
        cursor: "pointer",
        transition: "border-color 150ms, color 150ms",
        ...style,
      }}
      onMouseEnter={(e) => {
        (e.currentTarget as HTMLElement).style.borderColor = "var(--border-hi)";
        (e.currentTarget as HTMLElement).style.color = "var(--text-2)";
      }}
      onMouseLeave={(e) => {
        (e.currentTarget as HTMLElement).style.borderColor = "var(--border-hi)";
        (e.currentTarget as HTMLElement).style.color = "var(--text-3)";
      }}
    >
      {children}
    </button>
  );
}

/* ────────────────────────────────────────────────────────────
   Step 1 — Ollama Health
──────────────────────────────────────────────────────────── */

function StepOllama({ onNext }: { onNext: () => void }) {
  const [status, setStatus] = useState<OllamaStatus>({
    available: false,
    models: [],
    checking: true,
  });

  const check = useCallback(async () => {
    setStatus((s) => ({ ...s, checking: true }));
    try {
      const result = await invoke<{ available: boolean; models: string[] }>(
        "check_ollama_health"
      );
      setStatus({ ...result, checking: false });
    } catch {
      setStatus({ available: false, models: [], checking: false });
    }
  }, []);

  useEffect(() => {
    check();
  }, [check]);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 24 }}>
      <div>
        <h2
          style={{
            fontFamily: "var(--font-display)",
            fontSize: 20,
            fontWeight: 700,
            color: "var(--text)",
            marginBottom: 6,
          }}
        >
          AI Backend
        </h2>
        <p style={{ fontSize: 13, color: "var(--text-2)", lineHeight: 1.6 }}>
          Cortex uses Ollama for local AI inference. No data leaves your machine.
        </p>
      </div>

      {/* Status card */}
      <div
        style={{
          background: "var(--surface-2)",
          border: `1px solid ${
            status.checking
              ? "var(--border)"
              : status.available
              ? "rgba(74,222,128,0.25)"
              : "rgba(248,113,113,0.25)"
          }`,
          borderRadius: 8,
          padding: "16px 20px",
          display: "flex",
          alignItems: "center",
          gap: 14,
          transition: "border-color 300ms",
        }}
      >
        <div style={{ flexShrink: 0 }}>
          {status.checking ? (
            <Spinner />
          ) : status.available ? (
            <span style={{ fontSize: 20 }}>✓</span>
          ) : (
            <span style={{ fontSize: 20, color: "var(--red)" }}>✗</span>
          )}
        </div>

        <div style={{ flex: 1 }}>
          <div
            style={{
              fontSize: 13,
              fontWeight: 600,
              color: status.checking
                ? "var(--text-2)"
                : status.available
                ? "var(--green)"
                : "var(--red)",
              marginBottom: 2,
            }}
          >
            {status.checking
              ? "Checking Ollama…"
              : status.available
              ? "Ollama running"
              : "Ollama not found"}
          </div>
          <div style={{ fontSize: 11, color: "var(--text-3)" }}>
            {status.checking
              ? "Connecting to localhost:11434"
              : status.available
              ? `${status.models.length} model${status.models.length !== 1 ? "s" : ""} available`
              : "Install Ollama to enable AI features"}
          </div>
        </div>

        {!status.checking && (
          <button
            onClick={check}
            style={{
              background: "var(--surface-3)",
              border: "1px solid var(--border-hi)",
              borderRadius: 4,
              padding: "4px 10px",
              fontSize: 10,
              fontFamily: "var(--font-mono)",
              color: "var(--text-3)",
              cursor: "pointer",
              letterSpacing: "0.04em",
            }}
          >
            RETRY
          </button>
        )}
      </div>

      {/* Model list when available */}
      {status.available && status.models.length > 0 && (
        <div>
          <div
            style={{
              fontSize: 10,
              fontFamily: "var(--font-mono)",
              color: "var(--text-3)",
              letterSpacing: "0.06em",
              textTransform: "uppercase",
              marginBottom: 8,
            }}
          >
            Installed Models
          </div>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
            {status.models.map((m) => (
              <span
                key={m}
                style={{
                  background: "var(--surface-3)",
                  border: "1px solid var(--border-hi)",
                  borderRadius: 4,
                  padding: "3px 8px",
                  fontSize: 11,
                  fontFamily: "var(--font-mono)",
                  color: "var(--amber)",
                }}
              >
                {m}
              </span>
            ))}
          </div>
        </div>
      )}

      {/* Missing models warning */}
      {status.available && status.models.length === 0 && (
        <div
          style={{
            background: "rgba(232,164,48,0.08)",
            border: "1px solid rgba(232,164,48,0.2)",
            borderRadius: 8,
            padding: "12px 16px",
          }}
        >
          <div style={{ fontSize: 12, color: "var(--amber)", fontWeight: 600, marginBottom: 6 }}>
            ⚠ No models installed
          </div>
          <p style={{ fontSize: 11, color: "var(--text-2)", lineHeight: 1.6, marginBottom: 10 }}>
            Pull a model to enable search and memory features:
          </p>
          <pre
            style={{
              fontFamily: "var(--font-mono)",
              fontSize: 11,
              color: "var(--green)",
              background: "var(--bg)",
              border: "1px solid var(--border)",
              borderRadius: 4,
              padding: "8px 10px",
            }}
          >
            {`ollama pull llama3\nollama pull nomic-embed-text`}
          </pre>
        </div>
      )}

      {/* Not available — install prompt */}
      {!status.checking && !status.available && (
        <div
          style={{
            background: "var(--red-dim)",
            border: "1px solid rgba(248,113,113,0.2)",
            borderRadius: 8,
            padding: "12px 16px",
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            gap: 12,
          }}
        >
          <div>
            <div style={{ fontSize: 12, color: "var(--red)", fontWeight: 600, marginBottom: 2 }}>
              Ollama not running
            </div>
            <div style={{ fontSize: 11, color: "var(--text-3)" }}>
              Download and install from ollama.ai
            </div>
          </div>
          <button
            onClick={() => open("https://ollama.ai")}
            style={{
              background: "var(--red)",
              color: "#fff",
              border: "none",
              borderRadius: 5,
              padding: "7px 14px",
              fontSize: 12,
              fontWeight: 600,
              cursor: "pointer",
              flexShrink: 0,
            }}
          >
            Install Ollama ↗
          </button>
        </div>
      )}

      <div style={{ display: "flex", justifyContent: "flex-end", marginTop: 8 }}>
        <AmberBtn onClick={onNext}>
          {status.available ? "Continue →" : "Skip for now →"}
        </AmberBtn>
      </div>
    </div>
  );
}

/* ────────────────────────────────────────────────────────────
   Step 2 — macOS Permissions
──────────────────────────────────────────────────────────── */

function StepPermissions({ onNext, onBack }: { onNext: () => void; onBack: () => void }) {
  const [permissions, setPermissions] = useState<PermissionItem[]>(PERMISSIONS);

  const toggleGranted = (id: string) => {
    setPermissions((prev) =>
      prev.map((p) => (p.id === id ? { ...p, granted: !p.granted } : p))
    );
  };

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 24 }}>
      <div>
        <h2
          style={{
            fontFamily: "var(--font-display)",
            fontSize: 20,
            fontWeight: 700,
            color: "var(--text)",
            marginBottom: 6,
          }}
        >
          macOS Permissions
        </h2>
        <p style={{ fontSize: 13, color: "var(--text-2)", lineHeight: 1.6 }}>
          Cortex needs system access to capture and index your activity. All data stays local.
        </p>
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        {permissions.map((perm) => (
          <div
            key={perm.id}
            style={{
              background: "var(--surface-2)",
              border: `1px solid ${perm.granted ? "rgba(74,222,128,0.25)" : "var(--border)"}`,
              borderRadius: 8,
              padding: "14px 16px",
              display: "flex",
              alignItems: "center",
              gap: 14,
              transition: "border-color 200ms",
            }}
          >
            {/* Checkbox */}
            <button
              onClick={() => toggleGranted(perm.id)}
              style={{
                width: 18,
                height: 18,
                borderRadius: 4,
                border: `1.5px solid ${perm.granted ? "var(--green)" : "var(--border-hi)"}`,
                background: perm.granted ? "rgba(74,222,128,0.15)" : "transparent",
                cursor: "pointer",
                flexShrink: 0,
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                fontSize: 10,
                color: "var(--green)",
                transition: "all 150ms",
              }}
            >
              {perm.granted ? "✓" : ""}
            </button>

            <div style={{ flex: 1 }}>
              <div
                style={{
                  fontSize: 13,
                  fontWeight: 600,
                  color: perm.granted ? "var(--text)" : "var(--text-2)",
                  marginBottom: 2,
                }}
              >
                {perm.label}
              </div>
              <div style={{ fontSize: 11, color: "var(--text-3)" }}>{perm.description}</div>
            </div>

            <button
              onClick={() => open(perm.deeplink)}
              style={{
                background: "var(--surface-3)",
                border: "1px solid var(--border-hi)",
                borderRadius: 5,
                padding: "5px 10px",
                fontSize: 10,
                fontFamily: "var(--font-mono)",
                color: "var(--amber)",
                cursor: "pointer",
                letterSpacing: "0.04em",
                flexShrink: 0,
              }}
            >
              OPEN →
            </button>
          </div>
        ))}
      </div>

      <p style={{ fontSize: 11, color: "var(--text-3)", lineHeight: 1.6 }}>
        After granting each permission in System Settings, check the box above to mark it done.
      </p>

      <div style={{ display: "flex", justifyContent: "space-between", marginTop: 8 }}>
        <GhostBtn onClick={onBack}>← Back</GhostBtn>
        <AmberBtn onClick={onNext}>Continue →</AmberBtn>
      </div>
    </div>
  );
}

/* ────────────────────────────────────────────────────────────
   Step 3 — Connect Sources
──────────────────────────────────────────────────────────── */

function StepSources({ onNext, onBack }: { onNext: () => void; onBack: () => void }) {
  const [connected, setConnected] = useState<ConnectedSources>({
    gmail: false,
    github: false,
    slack: false,
  });
  const [connecting, setConnecting] = useState<Partial<ConnectedSources>>({});

  const connect = async (source: keyof ConnectedSources) => {
    setConnecting((c) => ({ ...c, [source]: true }));
    // Suppress click-away-hide while the OAuth browser tab steals focus.
    await invoke("set_autohide", { enabled: false }).catch(() => {});
    try {
      if (source === "gmail") {
        // Real OAuth2 flow — opens browser, waits for callback
        const result = await invoke<{ connected: boolean; email: string | null }>("connect_google");
        if (result.connected) setConnected((c) => ({ ...c, gmail: true }));
      } else if (source === "github") {
        // Check if token already configured in ~/.cortex/config.toml
        const result = await invoke<{ connected: boolean; username: string | null }>("check_github_token");
        if (result.connected) setConnected((c) => ({ ...c, github: true }));
      } else {
        console.info(`${source} OAuth not yet implemented`);
      }
    } catch (e) {
      console.error(`connect ${source} failed`, e);
    } finally {
      setConnecting((c) => ({ ...c, [source]: false }));
      await invoke("set_autohide", { enabled: true }).catch(() => {});
    }
  };

  const sources: {
    id: keyof ConnectedSources;
    label: string;
    description: string;
    color: string;
    icon: string;
  }[] = [
    {
      id: "gmail",
      label: "Gmail",
      description: "Index emails, threads, and attachments",
      color: "#fb923c",
      icon: "✉",
    },
    {
      id: "github",
      label: "GitHub",
      description: "PRs, issues, commits across your repos",
      color: "#e879f9",
      icon: "⚙",
    },
    {
      id: "slack",
      label: "Slack",
      description: "Messages, threads, and shared files",
      color: "#818cf8",
      icon: "💬",
    },
  ];

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 24 }}>
      <div>
        <h2
          style={{
            fontFamily: "var(--font-display)",
            fontSize: 20,
            fontWeight: 700,
            color: "var(--text)",
            marginBottom: 6,
          }}
        >
          Connect Sources
        </h2>
        <p style={{ fontSize: 13, color: "var(--text-2)", lineHeight: 1.6 }}>
          Connect cloud services to include them in your unified search. All optional.
        </p>
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        {sources.map((src) => (
          <div
            key={src.id}
            style={{
              background: "var(--surface-2)",
              border: `1px solid ${connected[src.id] ? "rgba(74,222,128,0.25)" : "var(--border)"}`,
              borderRadius: 8,
              padding: "14px 16px",
              display: "flex",
              alignItems: "center",
              gap: 14,
              transition: "border-color 200ms",
            }}
          >
            <SourceTile pluginId={src.id === "gmail" ? "gmail" : src.id === "github" ? "github" : "slack"} size={34} />

            <div style={{ flex: 1 }}>
              <div
                style={{
                  fontSize: 13,
                  fontWeight: 600,
                  color: "var(--text)",
                  marginBottom: 2,
                }}
              >
                {src.label}
              </div>
              <div style={{ fontSize: 11, color: "var(--text-3)" }}>{src.description}</div>
            </div>

            {connected[src.id] ? (
              <span
                style={{
                  fontSize: 11,
                  fontFamily: "var(--font-mono)",
                  color: "var(--green)",
                  display: "flex",
                  alignItems: "center",
                  gap: 5,
                }}
              >
                <CheckIcon s={13} />
                Connected
              </span>
            ) : (
              <button
                onClick={() => connect(src.id)}
                disabled={!!connecting[src.id]}
                style={{
                  background: `${src.color}18`,
                  border: `1px solid ${src.color}40`,
                  borderRadius: 5,
                  padding: "6px 14px",
                  fontSize: 12,
                  fontWeight: 600,
                  color: src.color,
                  cursor: connecting[src.id] ? "wait" : "pointer",
                  flexShrink: 0,
                  display: "flex",
                  alignItems: "center",
                  gap: 6,
                  fontFamily: "var(--font-sans)",
                }}
              >
                {connecting[src.id] ? <Spinner /> : "Connect"}
              </button>
            )}
          </div>
        ))}
      </div>

      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: 8 }}>
        <GhostBtn onClick={onBack}>← Back</GhostBtn>
        <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
          <button
            onClick={onNext}
            style={{
              background: "none",
              border: "none",
              fontSize: 12,
              color: "var(--text-3)",
              cursor: "pointer",
              textDecoration: "underline",
              textDecorationColor: "var(--border-hi)",
            }}
          >
            Skip
          </button>
          <AmberBtn onClick={onNext}>Continue →</AmberBtn>
        </div>
      </div>
    </div>
  );
}

/* ────────────────────────────────────────────────────────────
   Step 4 — Indexing Progress
──────────────────────────────────────────────────────────── */

function StepIndexing({
  onComplete,
  onBack,
}: {
  onComplete: () => void;
  onBack: () => void;
}) {
  const [daemonStatus, setDaemonStatus] = useState<DaemonStatus>({
    pluginCounts: {},
    indexedItems: 0,
    activePlugins: [],
  });
  const [finishing, setFinishing] = useState(false);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const [terminals, setTerminals] = useState<string[]>([]);
  const [terminal, setTerminal] = useState<string>("Terminal");

  const poll = useCallback(async () => {
    try {
      const s = await invoke<DaemonStatus>("get_daemon_status");
      setDaemonStatus(s);
    } catch {
      // ignore polling errors
    }
  }, []);

  useEffect(() => {
    poll();
    intervalRef.current = setInterval(poll, 2000);
    invoke<string[]>("detect_terminals").then(ts => {
      setTerminals(ts);
      if (ts.length) setTerminal(ts[0]);
    }).catch(() => {});
    return () => {
      if (intervalRef.current) clearInterval(intervalRef.current);
    };
  }, [poll]);

  const chooseTerminal = (t: string) => {
    setTerminal(t);
    invoke("set_config", { key: "terminal", value: t }).catch(() => {});
  };

  const handleFinish = async () => {
    setFinishing(true);
    try {
      await invoke("set_onboarding_complete");
    } catch {
      // best-effort
    }
    localStorage.setItem("cortex_onboarding_complete", "true");
    onComplete();
  };

  // Estimate max count per plugin for progress bar (use actual or fallback to a large number)
  const getProgress = (plugin: string): number => {
    const count = (daemonStatus.pluginCounts[plugin] ?? 0) as number;
    // Show at least some progress once the plugin is active
    const isActive = daemonStatus.activePlugins.includes(plugin);
    if (!isActive) return 0;
    if (count === 0) return 5; // show a pulse
    // Softcap: 10k items = 100%
    return Math.min(100, Math.round((count / 10000) * 100));
  };

  const totalIndexed = daemonStatus.indexedItems;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 24 }}>
      <div>
        <h2
          style={{
            fontFamily: "var(--font-display)",
            fontSize: 20,
            fontWeight: 700,
            color: "var(--text)",
            marginBottom: 6,
          }}
        >
          Building Your Memory
        </h2>
        <p style={{ fontSize: 13, color: "var(--text-2)", lineHeight: 1.6 }}>
          Cortex is indexing your activity in the background. This may take a few minutes.
        </p>
      </div>

      {/* Total count */}
      <div
        style={{
          background: "var(--amber-dim)",
          border: "1px solid rgba(232,164,48,0.2)",
          borderRadius: 8,
          padding: "12px 16px",
          display: "flex",
          alignItems: "center",
          gap: 10,
        }}
      >
        <div
          style={{
            width: 8,
            height: 8,
            borderRadius: "50%",
            background: "var(--amber)",
            boxShadow: "0 0 8px var(--amber-pulse)",
            animation: "pulse-ring 1.8s ease-out infinite",
            flexShrink: 0,
          }}
        />
        <span
          style={{
            fontFamily: "var(--font-mono)",
            fontSize: 13,
            color: "var(--amber)",
            fontWeight: 600,
          }}
        >
          {totalIndexed.toLocaleString()} items indexed
        </span>
      </div>

      {/* Plugin progress bars */}
      <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        {PLUGINS.map((plugin) => {
          const count = (daemonStatus.pluginCounts[plugin] ?? 0) as number;
          const pct = getProgress(plugin);
          const isActive = daemonStatus.activePlugins.includes(plugin);

          return (
            <div key={plugin}>
              <div
                style={{
                  display: "flex",
                  justifyContent: "space-between",
                  alignItems: "center",
                  marginBottom: 5,
                }}
              >
                <span
                  style={{
                    fontSize: 11,
                    fontFamily: "var(--font-mono)",
                    color: isActive ? "var(--text-2)" : "var(--text-3)",
                    textTransform: "capitalize",
                    letterSpacing: "0.02em",
                  }}
                >
                  {plugin}
                </span>
                <span
                  style={{
                    fontSize: 10,
                    fontFamily: "var(--font-mono)",
                    color: count > 0 ? "var(--amber)" : "var(--text-3)",
                  }}
                >
                  {count > 0 ? count.toLocaleString() : isActive ? "scanning…" : "pending"}
                </span>
              </div>
              <div
                style={{
                  height: 3,
                  background: "var(--surface-3)",
                  borderRadius: 2,
                  overflow: "hidden",
                }}
              >
                <div
                  style={{
                    height: "100%",
                    width: `${pct}%`,
                    background:
                      pct > 0
                        ? "linear-gradient(90deg, var(--amber), rgba(232,164,48,0.5))"
                        : "transparent",
                    borderRadius: 2,
                    transition: "width 600ms var(--ease-out)",
                    minWidth: pct > 0 && pct < 8 ? 16 : 0,
                  }}
                />
              </div>
            </div>
          );
        })}
      </div>

      {/* Terminal preference */}
      {terminals.length > 0 && (
        <div style={{ marginTop: 18, padding: "14px 16px", borderRadius: 10, background: "rgba(255,255,255,0.04)", border: "1px solid rgba(255,255,255,0.08)" }}>
          <div style={{ fontSize: 11, fontWeight: 600, color: "rgba(255,255,255,0.32)", textTransform: "uppercase", letterSpacing: "0.06em", marginBottom: 10 }}>
            Terminal for running commands
          </div>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
            {terminals.map(t => (
              <button key={t} onClick={() => chooseTerminal(t)} style={{
                padding: "6px 14px", borderRadius: 7, cursor: "pointer", fontSize: 13,
                border: `1px solid ${terminal === t ? "rgba(255,200,90,0.4)" : "rgba(255,255,255,0.12)"}`,
                background: terminal === t ? "rgba(255,200,90,0.12)" : "rgba(255,255,255,0.04)",
                color: terminal === t ? "rgba(255,205,110,0.95)" : "rgba(255,255,255,0.6)",
              }}>{t}</button>
            ))}
          </div>
        </div>
      )}

      {/* Feature tips */}
      <div style={{
        marginTop: 18, padding: "14px 16px", borderRadius: 10,
        background: "rgba(255,255,255,0.04)", border: "1px solid rgba(255,255,255,0.08)",
      }}>
        <div style={{ fontSize: 11, fontWeight: 600, color: "rgba(255,255,255,0.32)", textTransform: "uppercase", letterSpacing: "0.06em", marginBottom: 10 }}>
          How to use Cortex
        </div>
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "8px 18px" }}>
          {[
            ["⌘K", "Open Cortex anywhere"],
            ["type", "Search apps, files, history"],
            [">", "Generate & run a command with AI"],
            ["?", "Ask Cortex AI a question"],
            ["math", "Type a calculation for an instant result"],
            ["⌘,", "Open Settings"],
          ].map(([k, v]) => (
            <div key={v} style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 12, color: "rgba(255,255,255,0.55)" }}>
              <span style={{
                fontFamily: "var(--font-mono)", fontSize: 11, color: "rgba(255,205,110,0.85)",
                background: "rgba(255,200,90,0.10)", border: "1px solid rgba(255,200,90,0.2)",
                borderRadius: 4, padding: "1px 6px", minWidth: 34, textAlign: "center", flexShrink: 0,
              }}>{k}</span>
              {v}
            </div>
          ))}
        </div>
      </div>

      <div style={{ display: "flex", justifyContent: "space-between", marginTop: 18 }}>
        <GhostBtn onClick={onBack}>← Back</GhostBtn>
        <AmberBtn onClick={handleFinish} disabled={finishing}>
          {finishing ? "Setting up…" : "Finish Setup ✓"}
        </AmberBtn>
      </div>
    </div>
  );
}

/* ────────────────────────────────────────────────────────────
   Main Onboarding Wizard
──────────────────────────────────────────────────────────── */

export default function Onboarding({ onComplete }: OnboardingProps) {
  const [step, setStep] = useState(0);
  const TOTAL_STEPS = 4;

  const next = useCallback(() => setStep((s) => Math.min(s + 1, TOTAL_STEPS - 1)), []);
  const back = useCallback(() => setStep((s) => Math.max(s - 1, 0)), []);

  // Keyboard nav
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape" && step > 0) back();
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [step, back]);

  return (
    <div
      style={{
        width: "100vw",
        height: "100vh",
        background: "rgba(20,20,26,0.78)",
        backdropFilter: "blur(48px) saturate(190%)",
        WebkitBackdropFilter: "blur(48px) saturate(190%)",
        display: "flex",
        flexDirection: "column",
        overflow: "hidden",
        borderRadius: 12,
      }}
    >
      <div style={{ flex: 1, display: "flex", flexDirection: "column", overflow: "hidden" }}>
        {/* Header */}
        <div
          style={{
            padding: "18px 24px 16px",
            borderBottom: "1px solid var(--border)",
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
          }}
        >
          <div data-tauri-drag-region style={{ display: "flex", alignItems: "center", gap: 9 }}>
            <CortexMark s={20} />
            <span
              style={{
                fontFamily: "var(--font-display)",
                fontWeight: 700,
                fontSize: 13,
                letterSpacing: "0.1em",
                color: "rgba(255,255,255,0.75)",
                textTransform: "uppercase",
              }}
            >
              Cortex Setup
            </span>
          </div>

          {/* Step dots */}
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            {Array.from({ length: TOTAL_STEPS }).map((_, i) => (
              <StepDot key={i} active={i === step} done={i < step} />
            ))}
          </div>
        </div>

        {/* Step content — scrollable */}
        <div
          style={{
            padding: "28px 28px 24px",
            flex: 1,
            minHeight: 0,
            overflowY: "auto",
            display: "flex",
            flexDirection: "column",
          }}
        >
          {step === 0 && <StepOllama onNext={next} />}
          {step === 1 && <StepPermissions onNext={next} onBack={back} />}
          {step === 2 && <StepSources onNext={next} onBack={back} />}
          {step === 3 && <StepIndexing onComplete={onComplete} onBack={back} />}
        </div>

        {/* Footer */}
        <div
          style={{
            padding: "10px 24px",
            borderTop: "1px solid var(--border)",
            background: "var(--bg)",
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
          }}
        >
          <span
            style={{
              fontSize: 10,
              fontFamily: "var(--font-mono)",
              color: "var(--text-3)",
            }}
          >
            Step {step + 1} of {TOTAL_STEPS}
          </span>
          <span
            style={{
              fontSize: 10,
              fontFamily: "var(--font-mono)",
              color: "var(--text-3)",
            }}
          >
            esc ← back
          </span>
        </div>
      </div>
    </div>
  );
}
