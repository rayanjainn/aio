export type SourceId =
  | "files"
  | "browser"
  | "shell"
  | "git"
  | "clipboard"
  | "screenshots"
  | "notes"
  | "docker"
  | "github"
  | "calendar"
  | "gmail"
  | "slack"
  | "obsidian"
  | "notion"
  | "apps"
  | "commands"
  | "calc"
  | "ai";

export type ResultAction = "open" | "run" | "copy" | "reveal" | "preview";

export interface SearchResult {
  id: string;
  pluginId: SourceId;
  title: string;
  subtitle?: string;
  content?: string;
  path?: string;
  url?: string;
  timestamp?: string; // ISO 8601
  sessionId?: string;
  score: number;
  action: ResultAction;
  metadata: Record<string, unknown>;
}

export interface SessionContext {
  id: string;
  startTime: string;
  endTime?: string;
  label: string;
  apps: string[];
  urls: string[];
  files: string[];
  commands: string[];
}

export interface SearchResponse {
  results: SearchResult[];
  sessions: SessionContext[];
  totalMs: number;
  sourceCounts: Partial<Record<SourceId, number>>;
  mode: "retrieval" | "execution";
  executionPreview?: string; // shell command preview if mode=execution
}

export interface DaemonStatus {
  recording: boolean;
  /** Sum of all plugin counts */
  indexedItems: number;
  /** Bytes under ~/.cortex/ */
  storageBytes: number;
  /** plugin_id → item count */
  pluginCounts: Partial<Record<SourceId, number>>;
  /** plugin_ids in registration order */
  activePlugins: string[];
  lastSync: string;
}
// Source labels + icons now live in components/icons.tsx (SVG, no emojis).
