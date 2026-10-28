/**
 * Setup.tsx — shown when Ollama is not ready.
 * Displays model pull instructions with live status polling.
 */
import { useState, useEffect } from "react";
import { invoke, openExternal } from "../lib/tauri";
import { CortexMark, CheckIcon, ExternalIcon } from "./icons";

type OllamaStatus =
  | "ready"
  | { missing_models: string[] }
  | "unavailable";

interface SetupProps {
  onReady: () => void;
}

const REQUIRED_MODELS = ["nomic-embed-text"];

export default function Setup({ onReady }: SetupProps) {
  const [status, setStatus] = useState<OllamaStatus>("unavailable");
  const [checking, setChecking] = useState(true);

  const check = async () => {
    setChecking(true);
    try {
      const s = await invoke<OllamaStatus>("get_ollama_status");
      setStatus(s);
      if (s === "ready") onReady();
    } catch {
      setStatus("unavailable");
    } finally {
      setChecking(false);
    }
  };

  useEffect(() => {
    check();
    const id = setInterval(check, 30_000);
    return () => clearInterval(id);
  }, []);

  const missing =
    typeof status === "object" && "missing_models" in status
      ? status.missing_models
      : status === "unavailable"
      ? REQUIRED_MODELS
      : [];

  return (
    <div style={{
      display: "flex", flexDirection: "column", alignItems: "center",
      justifyContent: "center", height: "100vh", padding: 40,
      fontFamily: "var(--font-sans)", color: "var(--text)",
      background: "rgba(20,20,26,0.92)",
      backdropFilter: "blur(48px) saturate(190%)", WebkitBackdropFilter: "blur(48px) saturate(190%)",
      borderRadius: 12, textAlign: "center", gap: 28,
    }}>
      {/* Logo */}
      <div style={{ marginBottom: 4 }}><CortexMark s={44} /></div>

      <div>
        <h1 style={{ fontFamily: "var(--font-display)", fontSize: 22, color: "var(--amber)", margin: "0 0 8px" }}>
          Cortex needs Ollama
        </h1>
        <p style={{ color: "var(--text-2)", fontSize: 14, margin: 0, maxWidth: 380, lineHeight: 1.6 }}>
          {status === "unavailable"
            ? "Ollama isn't running. Install it and pull the required models."
            : "Some required models are missing. Pull them to continue."}
        </p>
      </div>

      {/* Install Ollama */}
      {status === "unavailable" && (
        <div style={card}>
          <Step n={1} label="Install Ollama" />
          <button onClick={() => openExternal("https://ollama.ai")} style={{ ...linkBtn, display: "inline-flex", alignItems: "center", gap: 6, cursor: "pointer" }}>
            Download Ollama <ExternalIcon s={13} />
          </button>
          <p style={hint}>Then run: <code style={code}>ollama serve</code></p>
        </div>
      )}

      {/* Pull models */}
      <div style={card}>
        <Step n={status === "unavailable" ? 2 : 1} label="Pull required models" />
        <p style={{ ...hint, marginBottom: 12 }}>Run these in your terminal:</p>
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          {REQUIRED_MODELS.map(m => {
            const isMissing = missing.includes(m);
            return (
              <div key={m} style={{
                display: "flex", alignItems: "center", justifyContent: "space-between",
                padding: "8px 14px", borderRadius: 8,
                background: "var(--surface-2)",
                border: `1px solid ${isMissing ? "var(--border)" : "var(--green)"}`,
              }}>
                <span style={{ fontFamily: "var(--font-mono)", fontSize: 13, color: isMissing ? "var(--text-2)" : "var(--green)" }}>
                  ollama pull {m}
                </span>
                <span style={{ display: "flex", color: isMissing ? "rgba(255,255,255,0.2)" : "var(--green)" }}>
                  {isMissing
                    ? <span style={{ width: 14, height: 14, borderRadius: 4, border: "1.5px solid rgba(255,255,255,0.2)" }} />
                    : <CheckIcon s={15} />}
                </span>
              </div>
            );
          })}
        </div>
      </div>

      {/* Status + retry */}
      <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
        {checking ? (
          <span style={{ color: "var(--text-3)", fontSize: 13 }}>Checking…</span>
        ) : (
          <button onClick={check} style={{
            padding: "8px 20px", borderRadius: 8,
            border: "1px solid var(--amber)", background: "var(--amber-dim)",
            color: "var(--amber)", fontSize: 13, cursor: "pointer",
          }}>
            Re-check status
          </button>
        )}
        <span style={{
          fontSize: 12, color: status === "ready" ? "var(--green)" : "var(--text-3)",
        }}>
          {status === "ready" ? "● Ready" : "● Not ready — retrying every 30s"}
        </span>
      </div>
    </div>
  );
}

function Step({ n, label }: { n: number; label: string }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 12 }}>
      <span style={{
        width: 24, height: 24, borderRadius: "50%",
        background: "var(--amber)", color: "var(--bg)",
        display: "flex", alignItems: "center", justifyContent: "center",
        fontSize: 12, fontWeight: 700, flexShrink: 0,
      }}>{n}</span>
      <span style={{ fontSize: 14, fontWeight: 600, color: "var(--text)" }}>{label}</span>
    </div>
  );
}

const card: React.CSSProperties = {
  background: "var(--surface-1)", border: "1px solid var(--border)",
  borderRadius: 12, padding: "20px 24px",
  width: "100%", maxWidth: 420, textAlign: "left",
};

const linkBtn: React.CSSProperties = {
  display: "inline-block", padding: "8px 18px", borderRadius: 8,
  border: "1px solid var(--amber)", background: "var(--amber-dim)",
  color: "var(--amber)", fontSize: 13, textDecoration: "none",
  marginBottom: 12,
};

const hint: React.CSSProperties = {
  fontSize: 12, color: "var(--text-3)", margin: "8px 0 0",
};

const code: React.CSSProperties = {
  fontFamily: "var(--font-mono)", color: "var(--amber)",
  background: "var(--surface-3)", padding: "1px 6px", borderRadius: 4,
};
