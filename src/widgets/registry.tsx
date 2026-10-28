import type { ComponentType } from "react";
import type { SizeClass, WidgetConfig, WidgetProps } from "./types";
import { CalendarWidget, ClockWidget, CountdownWidget, FocusWidget, SearchWidget } from "./kinds/time";
import { BatteryWidget, SystemWidget } from "./kinds/system";
import { MusicWidget, PhotoWidget, WeatherWidget } from "./kinds/media";
import { ClipboardWidget, LauncherWidget, NotesWidget, TodosWidget } from "./kinds/productivity";
import { DockerWidget, GitWidget, GithubWidget } from "./kinds/dev";

export type FieldType = "text" | "select" | "toggle" | "number" | "date" | "zones" | "apps" | "repos";
export interface Field { key: string; label: string; type: FieldType; options?: { value: string; label: string }[]; placeholder?: string }

export interface WidgetKind {
  kind: string;
  name: string;
  description: string;
  category: "Essentials" | "Productivity" | "System" | "Developer";
  sizes: SizeClass[];
  defaults?: WidgetConfig;
  fields?: Field[];
  /** Content fills the card edge-to-edge (photos). */
  bleed?: boolean;
  Component: ComponentType<WidgetProps>;
}

export const KINDS: WidgetKind[] = [
  { kind: "clock", name: "Clock", description: "Analog or digital, with world clocks", category: "Essentials", sizes: ["s", "m", "l"], Component: ClockWidget,
    defaults: { style: "analog", seconds: true },
    fields: [
      { key: "style", label: "Style", type: "select", options: [{ value: "analog", label: "Analog" }, { value: "digital", label: "Digital" }] },
      { key: "tz", label: "Time zone", type: "text", placeholder: "Local (e.g. Europe/London)" },
      { key: "label", label: "Label", type: "text", placeholder: "Optional" },
      { key: "seconds", label: "Second hand", type: "toggle" },
      { key: "h24", label: "24-hour", type: "toggle" },
      { key: "zones", label: "World clocks", type: "zones" },
    ] },
  { kind: "calendar", name: "Calendar", description: "Today, the month and what's next", category: "Essentials", sizes: ["s", "m", "l"], Component: CalendarWidget },
  { kind: "weather", name: "Weather", description: "Now, hourly and 5-day forecast", category: "Essentials", sizes: ["s", "m", "l"], Component: WeatherWidget,
    defaults: { unit: "c" },
    fields: [
      { key: "city", label: "City", type: "text", placeholder: "e.g. Mumbai" },
      { key: "unit", label: "Units", type: "select", options: [{ value: "c", label: "Celsius" }, { value: "f", label: "Fahrenheit" }] },
    ] },
  { kind: "music", name: "Now Playing", description: "Spotify / Apple Music with controls", category: "Essentials", sizes: ["s", "m", "l"], Component: MusicWidget },
  { kind: "photo", name: "Photo Frame", description: "Rotating photos from a folder", category: "Essentials", sizes: ["s", "m", "l"], Component: PhotoWidget, bleed: true,
    fields: [
      { key: "folder", label: "Folder", type: "text", placeholder: "~/Pictures" },
      { key: "interval", label: "Change every (min)", type: "number" },
    ] },
  { kind: "search", name: "Cortex Search", description: "A search bar on your desktop", category: "Essentials", sizes: ["s", "m"], Component: SearchWidget },

  { kind: "notes", name: "Sticky Note", description: "Quick notes that stay put", category: "Productivity", sizes: ["s", "m", "l"], Component: NotesWidget,
    fields: [{ key: "title", label: "Title", type: "text", placeholder: "Notes" }] },
  { kind: "todos", name: "To-dos", description: "A tiny checklist", category: "Productivity", sizes: ["s", "m", "l"], Component: TodosWidget,
    fields: [{ key: "title", label: "Title", type: "text", placeholder: "To-dos" }] },
  { kind: "focus", name: "Focus Timer", description: "Pomodoro with automatic breaks", category: "Productivity", sizes: ["s", "m"], Component: FocusWidget,
    defaults: { minutes: 25, breakMinutes: 5 },
    fields: [
      { key: "minutes", label: "Focus minutes", type: "number" },
      { key: "breakMinutes", label: "Break minutes", type: "number" },
    ] },
  { kind: "countdown", name: "Countdown", description: "Days until a date that matters", category: "Productivity", sizes: ["s", "m"], Component: CountdownWidget,
    fields: [
      { key: "title", label: "Title", type: "text", placeholder: "Launch day" },
      { key: "date", label: "Date", type: "date" },
    ] },
  { kind: "launcher", name: "App Shelf", description: "One-click launch for your apps", category: "Productivity", sizes: ["s", "m", "l"], Component: LauncherWidget,
    fields: [{ key: "apps", label: "Apps", type: "apps" }] },
  { kind: "clipboard", name: "Clipboard", description: "Recent copies, click to re-copy", category: "Productivity", sizes: ["s", "m", "l"], Component: ClipboardWidget },

  { kind: "system", name: "System", description: "CPU, memory, disk and network", category: "System", sizes: ["s", "m", "l"], Component: SystemWidget },
  { kind: "battery", name: "Battery", description: "Charge and time remaining", category: "System", sizes: ["s", "m"], Component: BatteryWidget },

  { kind: "git", name: "Git Repos", description: "Branch, changes, ahead/behind", category: "Developer", sizes: ["s", "m", "l"], Component: GitWidget,
    fields: [{ key: "repos", label: "Repositories", type: "repos" }] },
  { kind: "docker", name: "Docker", description: "Containers with start/stop", category: "Developer", sizes: ["s", "m", "l"], Component: DockerWidget },
  { kind: "github", name: "GitHub", description: "Your contribution heatmap", category: "Developer", sizes: ["s", "m", "l"], Component: GithubWidget },
];

export const KIND_MAP: Record<string, WidgetKind> = Object.fromEntries(KINDS.map(k => [k.kind, k]));
