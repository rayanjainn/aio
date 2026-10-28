import { useEffect, useRef, useState } from "react";
import { invoke } from "../lib/tauri";

/**
 * Invoke `cmd` now and every `ms`, pausing while the page is hidden (widget
 * windows hidden via the tray stop polling). Keeps the last good value on error.
 */
export function usePoll<T>(cmd: string, args: Record<string, unknown> | undefined, ms: number, deps: unknown[] = []) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const argsRef = useRef(args);
  argsRef.current = args;

  useEffect(() => {
    let alive = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const tick = async () => {
      if (document.visibilityState !== "hidden") {
        try {
          const v = await invoke<T>(cmd, argsRef.current);
          if (alive) { setData(v); setError(null); }
        } catch (e) {
          if (alive) setError(typeof e === "string" ? e : e instanceof Error ? e.message : "Unavailable");
        } finally {
          if (alive) setLoading(false);
        }
      }
      if (alive) timer = setTimeout(tick, ms);
    };
    tick();
    const onVis = () => { if (document.visibilityState === "visible") { clearTimeout(timer); tick(); } };
    document.addEventListener("visibilitychange", onVis);
    return () => { alive = false; clearTimeout(timer); document.removeEventListener("visibilitychange", onVis); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cmd, ms, ...deps]);

  return { data, error, loading };
}

/** Re-render every `ms` (clocks, countdowns). */
export function useNow(ms = 1000): Date {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    // Align ticks to the wall clock so seconds flip together across widgets.
    let t: ReturnType<typeof setTimeout>;
    const loop = () => { setNow(new Date()); t = setTimeout(loop, ms - (Date.now() % ms)); };
    t = setTimeout(loop, ms - (Date.now() % ms));
    return () => clearTimeout(t);
  }, [ms]);
  return now;
}
