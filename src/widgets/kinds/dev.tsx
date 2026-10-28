import type { WidgetProps } from "../types";
import { usePoll } from "../../hooks/usePoll";
import { invoke } from "../../lib/tauri";
import { relative } from "../format";
import { BranchIcon, IconButton, PauseIcon, PlayIcon, WEmpty, WTitle } from "../ui";

/* ── Git repos ──────────────────────────────────────────── */

type Repo = { name: string; path: string; branch: string; ahead: number; behind: number; changed: number; lastCommit: string; lastCommitTs: number };

export function GitWidget({ size, config }: WidgetProps) {
  const paths: string[] = (config.repos ?? []).filter(Boolean);
  const n = size === "l" ? 6 : size === "m" ? 2 : 1;
  const { data } = usePoll<Repo[]>("git_repo_status", { paths, limit: n }, 30_000, [paths.join("|"), n]);
  const repos = data ?? [];
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      <WTitle>Repositories</WTitle>
      {repos.length === 0 ? <WEmpty>{data ? "No git repos found in ~/code, ~/projects…" : "Scanning…"}</WEmpty> : (
        <div style={{ display: "flex", flexDirection: "column", gap: size === "s" ? 4 : 10 }}>
          {repos.map(r => (
            <button key={r.path} data-nodrag className="w-listbtn" style={{ flexDirection: "column", alignItems: "stretch", gap: 3 }}
              onClick={() => invoke("launch_path", { path: r.path }).catch(() => {})}>
              <div style={{ display: "flex", justifyContent: "space-between", gap: 6 }}>
                <span style={{ fontSize: 13, fontWeight: 650, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{r.name}</span>
                <span className="tnum" style={{ fontSize: 11, display: "flex", gap: 6, flexShrink: 0 }}>
                  {r.changed > 0 && <span style={{ color: "rgba(var(--accent-rgb),0.95)" }}>●{r.changed}</span>}
                  {r.ahead > 0 && <span>↑{r.ahead}</span>}
                  {r.behind > 0 && <span>↓{r.behind}</span>}
                </span>
              </div>
              <div className="w-faint" style={{ display: "flex", alignItems: "center", gap: 4, fontSize: 11 }}>
                <BranchIcon s={11} /><span className="mono" style={{ whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{r.branch}</span>
              </div>
              {size !== "s" && (
                <div className="w-sub" style={{ fontSize: 11, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                  {r.lastCommit} · {relative(r.lastCommitTs)}
                </div>
              )}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

/* ── Docker ─────────────────────────────────────────────── */

type Container = { name: string; image: string; state: string; status: string };

export function DockerWidget({ size }: WidgetProps) {
  const { data, error } = usePoll<Container[]>("docker_containers", undefined, 5000);
  const list = (data ?? []).slice(0, size === "l" ? 9 : size === "m" ? 3 : 3);
  const running = (data ?? []).filter(c => c.state === "running").length;
  const act = (name: string, action: string) => invoke("docker_action", { name, action }).catch(() => {});
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      <WTitle right={data && <span className="w-faint tnum" style={{ fontSize: 11 }}>{running}/{data.length} up</span>}>Docker</WTitle>
      {error && !data ? <WEmpty>{error}</WEmpty> : list.length === 0 ? <WEmpty>No containers</WEmpty> : (
        <div style={{ display: "flex", flexDirection: "column", gap: 3 }}>
          {list.map(c => {
            const up = c.state === "running";
            return (
              <div key={c.name} className="w-row" style={{ gap: 8 }}>
                <span style={{ width: 7, height: 7, borderRadius: 9, flexShrink: 0, background: up ? "rgba(255,255,255,0.9)" : "rgba(255,255,255,0.22)",
                  boxShadow: up ? "0 0 6px rgba(255,255,255,0.6)" : "none" }} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 12.5, fontWeight: 600, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{c.name}</div>
                  {size !== "s" && <div className="w-faint" style={{ fontSize: 10.5, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{c.image} · {c.status}</div>}
                </div>
                {size !== "s" && (
                  <IconButton onClick={() => act(c.name, up ? "stop" : "start")} title={up ? "Stop" : "Start"}>
                    {up ? <PauseIcon s={12} /> : <PlayIcon s={12} />}
                  </IconButton>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

/* ── GitHub activity heatmap ────────────────────────────── */

type Activity = { repos: number; commits7d: number; days: number[] };

export function GithubWidget({ size }: WidgetProps) {
  const days = size === "s" ? 49 : size === "m" ? 140 : 140;
  const { data } = usePoll<Activity>("github_activity", { days }, 10 * 60_000, [days]);
  const d = data?.days ?? Array(days).fill(0);
  const max = Math.max(1, ...d);
  const weeks: number[][] = [];
  for (let i = 0; i < d.length; i += 7) weeks.push(d.slice(i, i + 7));
  const cell = size === "s" ? 15 : 13;
  const total = d.reduce((a, b) => a + b, 0);
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%", justifyContent: "space-between" }}>
      <WTitle right={<span className="w-faint tnum" style={{ fontSize: 11 }}>{data?.commits7d ?? 0} this week</span>}>GitHub</WTitle>
      <div style={{ display: "flex", gap: 3, justifyContent: "center" }}>
        {weeks.map((w, i) => (
          <div key={i} style={{ display: "flex", flexDirection: "column", gap: 3 }}>
            {w.map((v, j) => (
              <div key={j} title={`${v} commits`} style={{ width: cell, height: cell, borderRadius: 3.5,
                background: v === 0 ? "rgba(255,255,255,0.08)" : `rgba(255,255,255,${0.25 + 0.7 * (v / max)})` }} />
            ))}
          </div>
        ))}
      </div>
      {size === "l" && (
        <div style={{ display: "flex", justifyContent: "space-around", textAlign: "center" }}>
          <div><div className="w-big tnum">{total}</div><div className="w-faint" style={{ fontSize: 11 }}>commits · 20 wks</div></div>
          <div><div className="w-big tnum">{data?.repos ?? 0}</div><div className="w-faint" style={{ fontSize: 11 }}>repos</div></div>
        </div>
      )}
    </div>
  );
}
