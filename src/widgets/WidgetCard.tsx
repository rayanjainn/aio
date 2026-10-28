import { useRef } from "react";
import type { Widget, WidgetConfig } from "./types";
import { sizeClass } from "./types";
import { KIND_MAP } from "./registry";
import { useGlassPointer } from "../hooks/useGlassPointer";
import { ErrorBoundary } from "../components/ErrorBoundary";
import "./widgets.css";

/** The glass slab + widget content. Used by desktop windows and Studio previews. */
export function WidgetCard({ widget, setConfig, preview, edit, onRemove }: {
  widget: Widget; setConfig: (p: WidgetConfig) => void; preview?: boolean; edit?: boolean; onRemove?: () => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  useGlassPointer(ref);
  const k = KIND_MAP[widget.kind];
  const size = sizeClass(widget.w, widget.h);
  return (
    <div ref={ref} className={`glass w-card${k?.bleed ? " bleed" : ""}`} data-edit={edit ? "true" : undefined} style={{ borderRadius: 22 }}>
      {edit && onRemove && <button data-nodrag className="w-remove" onClick={onRemove} title="Remove widget">−</button>}
      <ErrorBoundary label={widget.kind}>
        {k ? <k.Component widget={widget} size={size} config={widget.config ?? {}} setConfig={setConfig} preview={preview} />
           : <div className="w-center w-sub">Unknown widget “{widget.kind}”</div>}
      </ErrorBoundary>
    </div>
  );
}
