import { AnimatePresence, motion } from "framer-motion";
import type { Toast } from "../hooks/useSearch";

export function ToastStack({
  toasts,
  onDismiss,
}: {
  toasts: Toast[];
  onDismiss: (id: string) => void;
}) {
  return (
    <div
      style={{
        position: "fixed",
        bottom: 24,
        left: "50%",
        transform: "translateX(-50%)",
        display: "flex",
        flexDirection: "column",
        gap: 6,
        zIndex: 9999,
        pointerEvents: "none",
      }}
    >
      <AnimatePresence>
        {toasts.map((t) => (
          <motion.div
            key={t.id}
            initial={{ opacity: 0, y: 8, scale: 0.97 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 4, scale: 0.97 }}
            transition={{ duration: 0.18, ease: [0.16, 1, 0.3, 1] }}
            onClick={() => onDismiss(t.id)}
            style={{
              pointerEvents: "auto",
              cursor: "pointer",
              display: "flex",
              alignItems: "center",
              gap: 10,
              padding: "9px 14px",
              borderRadius: 7,
              background:
                t.kind === "error"
                  ? "rgba(248, 113, 113, 0.12)"
                  : "rgba(74, 222, 128, 0.10)",
              border: `1px solid ${
                t.kind === "error"
                  ? "rgba(248, 113, 113, 0.28)"
                  : "rgba(74, 222, 128, 0.22)"
              }`,
              boxShadow: "0 4px 16px rgba(0,0,0,0.4)",
              backdropFilter: "blur(8px)",
              maxWidth: 440,
            }}
          >
            <span
              style={{
                fontSize: 11,
                fontFamily: "var(--font-mono)",
                fontWeight: 600,
                letterSpacing: "0.06em",
                color: t.kind === "error" ? "var(--red)" : "var(--green)",
                flexShrink: 0,
              }}
            >
              {t.kind === "error" ? "ERR" : "OK"}
            </span>
            <span
              style={{
                fontSize: 12,
                fontFamily: "var(--font-sans)",
                color: "var(--text-2)",
                overflow: "hidden",
                textOverflow: "ellipsis",
                whiteSpace: "nowrap",
              }}
            >
              {t.message}
            </span>
            <span
              style={{
                marginLeft: "auto",
                fontSize: 10,
                color: "var(--text-3)",
                fontFamily: "var(--font-mono)",
                flexShrink: 0,
              }}
            >
              ✕
            </span>
          </motion.div>
        ))}
      </AnimatePresence>
    </div>
  );
}
