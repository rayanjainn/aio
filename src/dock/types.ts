export type DockItem =
  | { type: "app"; name: string; path: string }
  | { type: "folder"; name: string; path: string }
  | { type: "widget"; kind: DockWidgetKind; config?: Record<string, unknown> | null }
  | { type: "separator" };

export type DockWidgetKind = "clock" | "battery" | "cpu" | "music" | "weather";

export interface DockConfig {
  enabled: boolean;
  edge: "bottom" | "left" | "right" | "top";
  iconSize: number;
  magnify: boolean;
  autohide: boolean;
  showRunning: boolean;
  hideSystemDock: boolean;
  items: DockItem[];
}

export const DOCK_WIDGETS: { kind: DockWidgetKind; name: string }[] = [
  { kind: "clock", name: "Clock" },
  { kind: "music", name: "Now Playing" },
  { kind: "cpu", name: "CPU" },
  { kind: "battery", name: "Battery" },
  { kind: "weather", name: "Weather" },
];
