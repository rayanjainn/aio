export function bytes(b: number, digits = 1): string {
  if (!Number.isFinite(b) || b <= 0) return "0 B";
  const u = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.min(u.length - 1, Math.floor(Math.log(b) / Math.log(1024)));
  return `${(b / 1024 ** i).toFixed(i < 2 ? 0 : digits)} ${u[i]}`;
}

export function rate(bps: number): string {
  return `${bytes(bps)}/s`;
}

export function duration(sec: number): string {
  const s = Math.max(0, Math.floor(sec));
  const m = Math.floor(s / 60);
  return `${m}:${String(s % 60).padStart(2, "0")}`;
}

export function uptime(sec: number): string {
  const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60);
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`;
}

export function relative(unixSec: number, now = Date.now()): string {
  const d = unixSec * 1000 - now;
  const abs = Math.abs(d), past = d < 0;
  const m = Math.round(abs / 60000), h = Math.round(abs / 3600000), days = Math.round(abs / 86400000);
  const v = m < 1 ? "now" : m < 60 ? `${m}m` : h < 24 ? `${h}h` : `${days}d`;
  if (v === "now") return v;
  return past ? `${v} ago` : `in ${v}`;
}

export function timeIn(date: Date, tz?: string, opts: Intl.DateTimeFormatOptions = { hour: "numeric", minute: "2-digit" }): string {
  try { return date.toLocaleTimeString([], { ...opts, timeZone: tz || undefined }); }
  catch { return date.toLocaleTimeString([], opts); }
}

/** Hour/minute/second of `date` in `tz` (for analog hands). */
export function partsIn(date: Date, tz?: string): { h: number; m: number; s: number } {
  try {
    const f = new Intl.DateTimeFormat("en-US", { timeZone: tz || undefined, hour12: false, hour: "numeric", minute: "numeric", second: "numeric" });
    const p = Object.fromEntries(f.formatToParts(date).map(x => [x.type, x.value]));
    return { h: (+p.hour) % 24, m: +p.minute, s: +p.second };
  } catch {
    return { h: date.getHours(), m: date.getMinutes(), s: date.getSeconds() };
  }
}

export function cityOf(tz: string): string {
  return tz.split("/").pop()!.replace(/_/g, " ");
}

/** Offset label like "+5:30" / "−3h" relative to local time. */
export function offsetLabel(date: Date, tz: string): string {
  try {
    const local = new Date(date.toLocaleString("en-US"));
    const there = new Date(date.toLocaleString("en-US", { timeZone: tz }));
    const mins = Math.round((there.getTime() - local.getTime()) / 60000);
    if (mins === 0) return "Local";
    const sign = mins > 0 ? "+" : "−";
    const a = Math.abs(mins);
    return `${sign}${Math.floor(a / 60)}${a % 60 ? `:${String(a % 60).padStart(2, "0")}` : "h"}`;
  } catch { return ""; }
}

export const toF = (c: number) => c * 9 / 5 + 32;
export const temp = (c: number, unit: string) => `${Math.round(unit === "f" ? toF(c) : c)}°`;
