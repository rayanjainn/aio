import { useState, useCallback, useRef, useEffect } from "react";
import type { SearchResponse, DaemonStatus } from "../types";
import { IN_TAURI, invoke } from "../lib/tauri";

/* ─── Initial / fallback state ──────────────────────────── */

const EMPTY_STATUS: DaemonStatus = {
  recording:    false,
  indexedItems: 0,
  storageBytes: 0,
  pluginCounts: {},
  activePlugins: [],
  lastSync:     new Date().toISOString(),
};

/* ─── Toast ─────────────────────────────────────────────── */

export interface Toast {
  id:      string;
  message: string;
  kind:    "error" | "info";
}

let toastSeq = 0;
function makeToast(message: string, kind: Toast["kind"] = "error"): Toast {
  return { id: String(++toastSeq), message, kind };
}

/* ─── Hook ──────────────────────────────────────────────── */

export function useSearch() {
  const [query,          setQueryState]     = useState("");
  const [response,       setResponse]       = useState<SearchResponse | null>(null);
  const [loading,        setLoading]        = useState(false);
  const [status,         setStatus]         = useState<DaemonStatus>(EMPTY_STATUS);
  const [toasts,         setToasts]         = useState<Toast[]>([]);
  const [ollamaHealth,   setOllamaHealth]   = useState<{
    available: boolean; missingModels: string[];
  } | null>(null);

  const debounceRef = useRef<ReturnType<typeof setTimeout>>();

  /* ── Toast helpers ─────────────────────────────────────── */
  const pushToast = useCallback((message: string, kind: Toast["kind"] = "error") => {
    const t = makeToast(message, kind);
    setToasts((prev) => [...prev, t]);
    setTimeout(() => setToasts((prev) => prev.filter((x) => x.id !== t.id)), 4_000);
  }, []);

  const dismissToast = useCallback((id: string) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
  }, []);

  /* ── Daemon status (once on mount) ─────────────────────── */
  useEffect(() => {
    if (!IN_TAURI) return;
    invoke<DaemonStatus>("get_daemon_status").then(setStatus).catch(() => {});
  }, []);

  /* ── Ollama health ─────────────────────────────────────── */
  useEffect(() => {
    if (!IN_TAURI) return;
    invoke<{ available: boolean; missingModels: string[] }>("check_ollama_health")
      .then(r => setOllamaHealth({ available: r.available, missingModels: r.missingModels ?? [] }))
      .catch(() => setOllamaHealth({ available: false, missingModels: [] }));
  }, []);

  /* ── Default suggestions (apps + recents) for empty query ── */
  const loadSuggestions = useCallback(async () => {
    if (!IN_TAURI) { setResponse(null); return; }
    try {
      const res = await invoke<SearchResponse>("get_suggestions");
      console.debug("[cortex] suggestions", res.results.length);
      setResponse(res.results.length ? res : null);
    } catch (e) {
      console.error("[cortex] get_suggestions failed", e);
      setResponse(null);
    }
  }, []);

  useEffect(() => { loadSuggestions(); }, [loadSuggestions]);

  /* ── Core search ───────────────────────────────────────── */
  const search = useCallback((q: string) => {
    clearTimeout(debounceRef.current);

    const trimmed = q.trim();
    if (!trimmed) {
      setLoading(false);
      loadSuggestions();
      return;
    }

    // Prefix modes (> run · ? ask · : emoji) are handled entirely in the UI —
    // don't run a backend file/source search on the question/command text.
    if (/^[>?:]/.test(trimmed)) {
      setLoading(false);
      setResponse({ results: [], sessions: [], totalMs: 0, sourceCounts: {}, mode: "retrieval" });
      return;
    }

    setLoading(true);

    debounceRef.current = setTimeout(async () => {
      try {
        if (!IN_TAURI) {
          setResponse({ results: [], sessions: [], totalMs: 0, sourceCounts: {}, mode: "retrieval" });
          return;
        }
        const t0 = performance.now();
        // `search` takes a `req: SearchRequest` struct param — wrap accordingly.
        const res = await invoke<SearchResponse>("search", {
          req: { query: q, sourceFilter: null, limit: 25 },
        });
        console.debug(`[cortex] search "${q}" → ${res.results.length} results in ${(performance.now() - t0).toFixed(0)}ms`);
        setResponse(res);
      } catch (err) {
        console.error("[cortex] search failed", err);
        pushToast(err instanceof Error ? err.message : typeof err === "string" ? err : "Search failed");
        setResponse(null);
      } finally {
        setLoading(false);
      }
    }, 110);
  }, [pushToast, loadSuggestions]);

  const setQuery = useCallback((q: string) => {
    setQueryState(q);
    search(q);
  }, [search]);

  /* ── Execute a result ──────────────────────────────────── */
  const execute = useCallback(async (resultId: string) => {
    if (!IN_TAURI) return;
    try {
      await invoke<void>("execute_result", { resultId });
    } catch (err) {
      pushToast(err instanceof Error ? err.message : "Execute failed");
    }
  }, [pushToast]);

  useEffect(() => () => clearTimeout(debounceRef.current), []);

  return {
    query, setQuery, response, loading,
    status, toasts, dismissToast, execute,
    ollamaHealth,
  };
}
