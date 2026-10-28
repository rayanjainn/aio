import { useState, useEffect, useRef } from "react";
import type { DaemonStatus } from "../types";
import { IN_TAURI, invoke } from "../lib/tauri";

const EMPTY_STATUS: DaemonStatus = {
  recording:    false,
  indexedItems: 0,
  storageBytes: 0,
  pluginCounts: {},
  activePlugins: [],
  lastSync:     new Date().toISOString(),
};

async function fetchStatus(): Promise<DaemonStatus> {
  if (!IN_TAURI) return EMPTY_STATUS;
  return invoke<DaemonStatus>("get_daemon_status");
}

/**
 * Polls `get_daemon_status` every `intervalMs` (default 5 000ms).
 * First fetch fires immediately on mount.
 */
export function useStatus(intervalMs = 5_000) {
  const [status,   setStatus]   = useState<DaemonStatus>(EMPTY_STATUS);
  const [fetching, setFetching] = useState(false);
  const [error,    setError]    = useState<string | null>(null);
  const timerRef = useRef<ReturnType<typeof setInterval>>();
  const busy = useRef(false);

  async function poll() {
    if (busy.current) return;
    busy.current = true;
    setFetching(true);
    try {
      const s = await fetchStatus();
      setStatus(s);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      busy.current = false;
      setFetching(false);
    }
  }

  // ⌘⇧P / tray toggles flip the REC indicator instantly instead of on next poll.
  useEffect(() => {
    if (!IN_TAURI) return;
    let unlisten: (() => void) | undefined;
    import("@tauri-apps/api/event").then(({ listen }) =>
      listen<boolean>("recording-changed", e => setStatus(s => ({ ...s, recording: e.payload })))
        .then(u => { unlisten = u; }));
    return () => unlisten?.();
  }, []);

  useEffect(() => {
    poll();
    timerRef.current = setInterval(poll, intervalMs);
    return () => clearInterval(timerRef.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [intervalMs]);

  return { status, fetching, error };
}
