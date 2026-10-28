import { useEffect, type RefObject } from "react";

/**
 * Drives the specular sheen on `.glass` / `.glass-window` surfaces: writes the
 * pointer position into --mx / --my. rAF-throttled, no React re-renders.
 */
export function useGlassPointer(ref: RefObject<HTMLElement>): void {
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    let frame = 0;
    const onMove = (e: PointerEvent) => {
      if (frame) return;
      frame = requestAnimationFrame(() => {
        frame = 0;
        const r = el.getBoundingClientRect();
        el.style.setProperty("--mx", `${e.clientX - r.left}px`);
        el.style.setProperty("--my", `${e.clientY - r.top}px`);
      });
    };
    el.addEventListener("pointermove", onMove);
    return () => { el.removeEventListener("pointermove", onMove); cancelAnimationFrame(frame); };
  }, [ref]);
}
