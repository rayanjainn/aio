export type Layer = "desktop" | "floating";
export type SizeClass = "s" | "m" | "l";

/* eslint-disable @typescript-eslint/no-explicit-any */
export type WidgetConfig = Record<string, any>;

export interface Widget {
  id: string;
  kind: string;
  x: number; y: number; w: number; h: number;
  layer: Layer;
  locked: boolean;
  config: WidgetConfig;
}

export interface WidgetProps {
  widget: Widget;
  size: SizeClass;
  config: WidgetConfig;
  setConfig: (patch: WidgetConfig) => void;
  /** Rendered as a thumbnail in the Studio gallery. */
  preview?: boolean;
}

export const SIZES: Record<SizeClass, { w: number; h: number; label: string }> = {
  s: { w: 170, h: 170, label: "Small" },
  m: { w: 360, h: 170, label: "Medium" },
  l: { w: 360, h: 380, label: "Large" },
};

export function sizeClass(w: number, h: number): SizeClass {
  if (h >= 300) return "l";
  if (w >= 300) return "m";
  return "s";
}
