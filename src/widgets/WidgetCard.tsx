import { useCallback, useRef, useState } from "react";
import { BrandContext, type Brand } from "./brand";
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
  const [brand, setBrandState] = useState<Brand | null>(null);
  const setBrand = useCallback((b: Brand | null) => setBrandState(cur => (cur?.rgb === b?.rgb && cur?.base === b?.base ? cur : b)), []);
  const brandVars = brand ? {
    ["--brand-rgb" as string]: brand.rgb,
    ["--brand-base" as string]: brand.base ?? brand.rgb,
    // Readable glyph colour on a solid brand button (black on Spotify green).
    ["--brand-ink" as string]: luminance(brand.rgb) > 0.6 ? "#0b0b0d" : "#fff",
  } : {};
  return (
    <BrandContext.Provider value={setBrand}>
    <div ref={ref} className={`glass w-card${k?.bleed ? " bleed" : ""}${brand ? " branded" : ""}${brand?.base ? " based" : ""}`} data-edit={edit ? "true" : undefined}
      style={{ borderRadius: 22, ...brandVars }}>
      {edit && onRemove && <button data-nodrag className="w-remove" onClick={onRemove} title="Remove widget">−</button>}
      <ErrorBoundary label={widget.kind}>
        {k ? <k.Component widget={widget} size={size} config={widget.config ?? {}} setConfig={setConfig} preview={preview} />
           : <div className="w-center w-sub">Unknown widget “{widget.kind}”</div>}
      </ErrorBoundary>
    </div>
    </BrandContext.Provider>
  );
}

function luminance(rgb: string): number {
  const [r, g, b] = rgb.split(",").map(v => +v / 255);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
