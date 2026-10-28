import { useState, useEffect, useRef } from "react";
import { invoke } from "../lib/tauri";
import { SparkleIcon } from "./icons";

interface ExecutorPlan {
  command: string;
  explanation: string;
  is_destructive: boolean;
}

interface ExecOutput {
  line: string;
  is_stderr: boolean;
  exit_code: number | null;
}

interface ExecutionConfirmProps {
  plan: ExecutorPlan | null;
  onClose: () => void;
  onConfirm?: (command: string) => void;
}

type Phase = "confirm" | "running" | "done";

export default function ExecutionConfirm({ plan, onClose, onConfirm }: ExecutionConfirmProps) {
  const [phase, setPhase] = useState<Phase>("confirm");
  const [output, setOutput] = useState<ExecOutput[]>([]);
  const [exitCode, setExitCode] = useState<number | null>(null);
  const outputRef = useRef<HTMLDivElement>(null);

  // Escape to close
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [onClose]);

  // Auto-scroll output
  useEffect(() => {
    if (outputRef.current) {
      outputRef.current.scrollTop = outputRef.current.scrollHeight;
    }
  }, [output]);

  if (!plan) return null;

  const run = async () => {
    setPhase("running");
    onConfirm?.(plan.command);
    try {
      const lines = await invoke<ExecOutput[]>("run_execution", { command: plan.command });
      setOutput(lines);
      const last = lines[lines.length - 1];
      setExitCode(last?.exit_code ?? 0);
    } catch (e) {
      setOutput([{ line: String(e), is_stderr: true, exit_code: 1 }]);
      setExitCode(1);
    }
    setPhase("done");
  };

  return (
    <div
      data-cortex-overlay
      style={{
        position: "fixed", inset: 0,
        background: "rgba(0,0,0,0.75)",
        backdropFilter: "blur(12px)", WebkitBackdropFilter: "blur(12px)",
        display: "flex", alignItems: "center", justifyContent: "center",
        zIndex: 2000, fontFamily: "var(--font-sans)",
      }}
      onClick={e => e.target === e.currentTarget && onClose()}
    >
      <div style={{
        width: 560, borderRadius: 12,
        background: "var(--surface-1)",
        border: "1px solid var(--border)",
        boxShadow: "0 32px 80px rgba(0,0,0,0.6)",
        overflow: "hidden",
      }}>
        {/* Header */}
        <div style={{
          padding: "16px 20px", borderBottom: "1px solid var(--border)",
          display: "flex", alignItems: "center", gap: 10,
        }}>
          <span style={{ display: "flex", color: "var(--amber)" }}><SparkleIcon s={16} /></span>
          <span style={{
            fontFamily: "var(--font-display)", fontSize: 15,
            color: "var(--text)", fontWeight: 600,
          }}>
            {phase === "confirm" ? "Execute Command" : phase === "running" ? "Running…" : "Execution Complete"}
          </span>
          <button onClick={onClose} style={{
            marginLeft: "auto", background: "none", border: "none",
            color: "var(--text-3)", fontSize: 18, cursor: "pointer", lineHeight: 1,
          }}>×</button>
        </div>

        {/* Command block */}
        <div style={{ padding: "16px 20px" }}>
          <div style={{
            background: "var(--surface-0)", borderRadius: 8,
            border: `1px solid ${plan.is_destructive ? "rgba(255,255,255,0.35)" : "var(--border)"}`,
            padding: "12px 16px",
            fontFamily: "var(--font-mono)", fontSize: 13, color: "var(--amber)",
            wordBreak: "break-all",
          }}>
            <span style={{ color: "var(--text-3)" }}>$ </span>
            {plan.command}
          </div>
        </div>

        {/* Explanation */}
        {plan.explanation && (
          <div style={{ padding: "0 20px 12px", fontSize: 13, color: "var(--text-2)", lineHeight: 1.6 }}>
            {plan.explanation}
          </div>
        )}

        {/* Destructive warning */}
        {plan.is_destructive && (
          <div style={{
            margin: "0 20px 12px",
            padding: "8px 14px", borderRadius: 8,
            background: "var(--red-dim)", border: "1px solid rgba(255,255,255,0.35)",
            color: "var(--red)", fontSize: 12, display: "flex", alignItems: "center", gap: 8,
          }}>
            ⚠ Destructive operation — cannot be undone
          </div>
        )}

        {/* Terminal output (running/done) */}
        {(phase === "running" || phase === "done") && (
          <div ref={outputRef} style={{
            margin: "0 20px 16px",
            background: "#0a0a0a", borderRadius: 8,
            border: "1px solid var(--border)",
            padding: "12px", maxHeight: 220, overflowY: "auto",
            fontFamily: "var(--font-mono)", fontSize: 12, lineHeight: 1.6,
          }}>
            {phase === "running" && output.length === 0 && (
              <span style={{ color: "var(--text-3)" }}>
                <Spinner /> Running…
              </span>
            )}
            {output.map((o, i) => (
              <div key={i} style={{
                color: o.is_stderr ? "var(--red)" : "rgba(255,255,255,0.9)",
                wordBreak: "break-all",
              }}>
                {o.line}
              </div>
            ))}
          </div>
        )}

        {/* Exit code badge */}
        {phase === "done" && exitCode !== null && (
          <div style={{ padding: "0 20px 16px" }}>
            <span style={{
              display: "inline-flex", alignItems: "center", gap: 6,
              padding: "4px 12px", borderRadius: 20, fontSize: 12,
              fontFamily: "var(--font-mono)",
              border: `1px solid ${exitCode === 0 ? "var(--green)" : "var(--red)"}`,
              color: exitCode === 0 ? "var(--green)" : "var(--red)",
              background: exitCode === 0 ? "var(--green-dim)" : "var(--red-dim)",
            }}>
              {exitCode === 0 ? "✓" : "✗"} Exit {exitCode}
            </span>
          </div>
        )}

        {/* Actions */}
        <div style={{
          padding: "14px 20px", borderTop: "1px solid var(--border)",
          display: "flex", justifyContent: "flex-end", gap: 10,
        }}>
          {phase === "confirm" && (
            <>
              <button onClick={onClose} style={cancelBtn}>Cancel</button>
              <button onClick={run} style={{
                ...confirmBtn,
                background: plan.is_destructive ? "var(--red-dim)" : "var(--amber-dim)",
                border: `1px solid ${plan.is_destructive ? "var(--red)" : "var(--amber)"}`,
                color: plan.is_destructive ? "var(--red)" : "var(--amber)",
              }}>
                Run Command →
              </button>
            </>
          )}
          {phase === "running" && (
            <button onClick={onClose} style={cancelBtn}>Cancel</button>
          )}
          {phase === "done" && (
            <button onClick={onClose} style={confirmBtn}>Close</button>
          )}
        </div>
      </div>
    </div>
  );
}

function Spinner() {
  const [frame, setFrame] = useState(0);
  const chars = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"];
  useEffect(() => {
    const t = setInterval(() => setFrame(f => (f + 1) % chars.length), 80);
    return () => clearInterval(t);
  }, []);
  return <span style={{ color: "var(--amber)" }}>{chars[frame]} </span>;
}

const cancelBtn: React.CSSProperties = {
  padding: "8px 16px", borderRadius: 8,
  border: "1px solid var(--border)", background: "var(--surface-2)",
  color: "var(--text-2)", fontSize: 13, cursor: "pointer",
};

const confirmBtn: React.CSSProperties = {
  padding: "8px 18px", borderRadius: 8,
  border: "1px solid var(--amber)", background: "var(--amber-dim)",
  color: "var(--amber)", fontSize: 13, cursor: "pointer", fontWeight: 600,
};
