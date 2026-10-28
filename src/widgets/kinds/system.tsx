import { useEffect, useRef, useState } from "react";
import type { WidgetProps } from "../types";
import { usePoll } from "../../hooks/usePoll";
import { bytes, rate, uptime } from "../format";
import { ArrowDownIcon, ArrowUpIcon, BoltIcon, Ring, Sparkline, WEmpty, WTitle, loadColor } from "../ui";

export interface SysStats {
  cpu: number; cores: number[];
  memUsed: number; memTotal: number;
  diskUsed: number; diskTotal: number;
  netRx: number; netTx: number;
  battery: { percent: number; charging: boolean; minutesLeft: number | null } | null;
  uptime: number; load: [number, number, number];
}

/** Rolling history of a sampled value (for sparklines). */
function useHistory(value: number | undefined, len = 40): number[] {
  const ref = useRef<number[]>([]);
  const [, bump] = useState(0);
  useEffect(() => {
    if (value === undefined || !Number.isFinite(value)) return;
    ref.current = [...ref.current, value].slice(-len);
    bump(x => x + 1);
  }, [value, len]);
  return ref.current;
}

function Gauge({ label, value, detail, size }: { label: string; value: number; detail: string; size: number }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 5 }}>
      <Ring value={value} size={size} stroke={size > 60 ? 7 : 6} color={loadColor(value)}>
        <span className="tnum" style={{ fontSize: size > 60 ? 15 : 13, fontWeight: 700 }}>{Math.round(value * 100)}%</span>
      </Ring>
      <div style={{ textAlign: "center", lineHeight: 1.2 }}>
        <div style={{ fontSize: 11.5, fontWeight: 600 }}>{label}</div>
        <div className="w-faint tnum" style={{ fontSize: 10 }}>{detail}</div>
      </div>
    </div>
  );
}

export function SystemWidget({ size }: WidgetProps) {
  const { data: s } = usePoll<SysStats>("sys_stats", undefined, 2000);
  const cpuHist = useHistory(s?.cpu);
  const rxHist = useHistory(s?.netRx);
  if (!s) return <div className="skeleton" style={{ width: "100%", height: "100%" }} />;
  const mem = s.memTotal ? s.memUsed / s.memTotal : 0;
  const disk = s.diskTotal ? s.diskUsed / s.diskTotal : 0;
  const cpu = s.cpu / 100;

  if (size === "s") return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%", justifyContent: "space-between" }}>
      <WTitle right={<span className="w-faint tnum" style={{ fontSize: 10 }}>{uptime(s.uptime)}</span>}>System</WTitle>
      <div style={{ display: "flex", justifyContent: "space-around" }}>
        <Gauge label="CPU" value={cpu} detail={`${s.cores.length} cores`} size={58} />
        <Gauge label="Memory" value={mem} detail={bytes(s.memUsed)} size={58} />
      </div>
    </div>
  );

  const net = (
    <div style={{ display: "flex", flexDirection: "column", gap: 4, minWidth: 0 }}>
      <div style={{ display: "flex", gap: 10, fontSize: 11.5 }} className="tnum">
        <span style={{ display: "flex", alignItems: "center", gap: 3, color: "rgba(255,255,255,0.85)" }}><ArrowDownIcon s={11} />{rate(s.netRx)}</span>
        <span style={{ display: "flex", alignItems: "center", gap: 3, color: "rgba(255,255,255,0.55)" }}><ArrowUpIcon s={11} />{rate(s.netTx)}</span>
      </div>
      <Sparkline data={rxHist} width={size === "l" ? 300 : 120} height={size === "l" ? 34 : 26} color="rgba(255,255,255,0.8)" />
    </div>
  );

  if (size === "m") return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%", justifyContent: "space-between" }}>
      <WTitle right={<span className="w-faint tnum" style={{ fontSize: 10 }}>up {uptime(s.uptime)}</span>}>System</WTitle>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <Gauge label="CPU" value={cpu} detail={`load ${s.load[0].toFixed(1)}`} size={60} />
        <Gauge label="Memory" value={mem} detail={`${bytes(s.memUsed)} / ${bytes(s.memTotal, 0)}`} size={60} />
        <Gauge label="Disk" value={disk} detail={`${bytes(s.diskTotal - s.diskUsed, 0)} free`} size={60} />
        {net}
      </div>
    </div>
  );

  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%", gap: 12 }}>
      <WTitle right={<span className="w-faint tnum" style={{ fontSize: 10 }}>up {uptime(s.uptime)}</span>}>System</WTitle>
      <div style={{ display: "flex", justifyContent: "space-around" }}>
        <Gauge label="CPU" value={cpu} detail={`load ${s.load[0].toFixed(2)}`} size={74} />
        <Gauge label="Memory" value={mem} detail={`${bytes(s.memUsed)} / ${bytes(s.memTotal, 0)}`} size={74} />
        <Gauge label="Disk" value={disk} detail={`${bytes(s.diskTotal - s.diskUsed, 0)} free`} size={74} />
      </div>
      <div>
        <div className="w-faint" style={{ fontSize: 10.5, marginBottom: 4 }}>CPU · last 80s</div>
        <Sparkline data={cpuHist} width={316} height={40} max={100} color={loadColor(cpu)} />
      </div>
      <div style={{ display: "grid", gridTemplateColumns: `repeat(${Math.min(s.cores.length, 16)}, 1fr)`, gap: 3, alignItems: "end", height: 34 }}>
        {s.cores.slice(0, 16).map((c, i) => (
          <div key={i} style={{ height: `${Math.max(6, c)}%`, borderRadius: 3, background: loadColor(c / 100), opacity: 0.85, transition: "height 600ms var(--ease-out)" }} />
        ))}
      </div>
      {net}
    </div>
  );
}

export function BatteryWidget({ size }: WidgetProps) {
  const { data: s } = usePoll<SysStats>("sys_stats", undefined, 15_000);
  const b = s?.battery;
  if (s && !b) return <WEmpty>No battery — this Mac runs on power</WEmpty>;
  if (!b) return <div className="skeleton" style={{ width: "100%", height: "100%" }} />;
  const v = b.percent / 100;
  const color = v < 0.2 && !b.charging ? "var(--accent)" : "rgba(255,255,255,0.92)";
  const left = b.minutesLeft != null ? `${Math.floor(b.minutesLeft / 60)}h ${b.minutesLeft % 60}m ${b.charging ? "to full" : "left"}` : b.charging ? "Charging" : "Calculating…";
  return (
    <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 18, height: "100%", flexDirection: size === "s" ? "column" : "row" }}>
      <Ring value={v} size={size === "s" ? 92 : 108} stroke={9} color={color}>
        {b.charging && <span style={{ color }}><BoltIcon s={14} /></span>}
        <span className="tnum" style={{ fontSize: size === "s" ? 20 : 24, fontWeight: 700 }}>{Math.round(b.percent)}%</span>
      </Ring>
      <div style={{ textAlign: size === "s" ? "center" : "left" }}>
        {size !== "s" && <div className="w-eyebrow" style={{ marginBottom: 4 }}>Battery</div>}
        <div className="w-sub">{left}</div>
      </div>
    </div>
  );
}
