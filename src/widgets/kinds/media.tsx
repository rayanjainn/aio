import { useEffect, useState } from "react";
import type { WidgetProps } from "../types";
import { useNow, usePoll } from "../../hooks/usePoll";
import { invoke } from "../../lib/tauri";
import { duration, temp } from "../format";
import { knownBrand, useCardBrand } from "../brand";
import { IconButton, MusicIcon, NextIcon, PauseIcon, PlayIcon, PrevIcon, WEmpty, WeatherIcon, weatherLabel } from "../ui";

/* ── Weather ────────────────────────────────────────────── */

interface Weather {
  location: string; tempC: number; feelsC: number; code: number; isDay: boolean;
  humidity: number; windKph: number; high: number; low: number;
  hourly: { t: number; tempC: number; code: number }[];
  daily: { t: number; high: number; low: number; code: number }[];
}

export function WeatherWidget({ size, config }: WidgetProps) {
  const city: string = config.city ?? "";
  const unit: string = config.unit ?? "c";
  const { data: w, error } = usePoll<Weather>("weather_get", { city }, 15 * 60_000, [city]);
  if (!city) return <WEmpty>Add a city in widget settings to see the forecast</WEmpty>;
  if (!w) return error ? <WEmpty>{error}</WEmpty> : <div className="skeleton" style={{ width: "100%", height: "100%" }} />;
  const head = (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>
      <div>
        <div style={{ fontSize: 13, fontWeight: 600 }}>{w.location}</div>
        <div className="w-huge tnum" style={{ lineHeight: 1.05 }}>{temp(w.tempC, unit)}</div>
      </div>
      {size !== "s" && <WeatherIcon code={w.code} day={w.isDay} size={34} />}
    </div>
  );
  const foot = (
    <div>
      {size === "s" && <WeatherIcon code={w.code} day={w.isDay} size={20} />}
      <div style={{ fontSize: 12, fontWeight: 500 }}>{weatherLabel(w.code)}</div>
      <div className="w-sub tnum">H:{temp(w.high, unit)} L:{temp(w.low, unit)}</div>
    </div>
  );
  const hourly = (
    <div style={{ display: "flex", justifyContent: "space-between" }}>
      {w.hourly.slice(0, 6).map((h, i) => (
        <div key={h.t} style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 4 }}>
          <span className="w-faint" style={{ fontSize: 10.5 }}>{i === 0 ? "Now" : new Date(h.t * 1000).toLocaleTimeString([], { hour: "numeric" })}</span>
          <WeatherIcon code={h.code} size={20} />
          <span className="tnum" style={{ fontSize: 12, fontWeight: 600 }}>{temp(h.tempC, unit)}</span>
        </div>
      ))}
    </div>
  );
  if (size === "s") return <div style={{ display: "flex", flexDirection: "column", justifyContent: "space-between", height: "100%" }}>{head}{foot}</div>;
  if (size === "m") return (
    <div style={{ display: "flex", flexDirection: "column", justifyContent: "space-between", height: "100%" }}>
      <div style={{ display: "flex", justifyContent: "space-between" }}>{head}<div style={{ textAlign: "right" }}>{foot}</div></div>
      {hourly}
    </div>
  );
  const lo = Math.min(...w.daily.map(d => d.low)), hi = Math.max(...w.daily.map(d => d.high));
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12, height: "100%" }}>
      <div style={{ display: "flex", justifyContent: "space-between" }}>{head}<div style={{ textAlign: "right" }}>{foot}</div></div>
      {hourly}
      <div className="w-divider" />
      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        {w.daily.slice(0, 5).map((d, i) => (
          <div key={d.t} style={{ display: "grid", gridTemplateColumns: "44px 26px 34px 1fr 34px", alignItems: "center", gap: 8, fontSize: 12.5 }}>
            <span style={{ fontWeight: 600 }}>{i === 0 ? "Today" : new Date(d.t * 1000).toLocaleDateString([], { weekday: "short" })}</span>
            <WeatherIcon code={d.code} size={18} />
            <span className="w-faint tnum" style={{ textAlign: "right" }}>{temp(d.low, unit)}</span>
            <div style={{ height: 4, borderRadius: 4, background: "rgba(255,255,255,0.12)", position: "relative" }}>
              <div style={{ position: "absolute", top: 0, bottom: 0, borderRadius: 4, background: "rgba(255,255,255,0.75)",
                left: `${((d.low - lo) / Math.max(1, hi - lo)) * 100}%`, right: `${100 - ((d.high - lo) / Math.max(1, hi - lo)) * 100}%` }} />
            </div>
            <span className="tnum">{temp(d.high, unit)}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

/* ── Now playing ────────────────────────────────────────── */

interface NowPlaying { app: string; state: string; title: string; artist: string; album: string; position: number; duration: number; artwork: string | null }

export function MusicWidget({ size }: WidgetProps) {
  const { data } = usePoll<NowPlaying>("now_playing", undefined, 2000);
  const now = useNow(500);
  const [sampledAt, setSampledAt] = useState(Date.now());
  useEffect(() => { setSampledAt(Date.now()); }, [data?.position, data?.title]);
  const np = data;
  const playing = np?.state === "playing";
  // Interpolate the playhead between 2s polls so the bar glides.
  const pos = np ? Math.min(np.duration, np.position + (playing ? (now.getTime() - sampledAt) / 1000 : 0)) : 0;
  // Spotify green-on-black, Apple Music red — follows whichever app is playing.
  useCardBrand(np && np.app && np.state !== "stopped" ? knownBrand(np.app === "Music" ? "apple music" : np.app) : null);
  const ctl = (action: string) => np?.app && invoke("media_control", { action, app: np.app }).catch(() => {});

  if (!np || !np.app || np.state === "stopped") return (
    <div className="w-center" style={{ gap: 8 }}>
      <div className="w-art" style={{ width: 54, height: 54 }}><MusicIcon s={22} /></div>
      <div className="w-sub">Not playing</div>
    </div>
  );
  const art = (sz: number) => (
    <div key={np.title} className="w-art anim-pop" style={{ width: sz, height: sz, transform: playing ? "none" : "scale(0.94)", transition: "transform 450ms var(--ease-spring)" }}>
      {np.artwork ? <img src={np.artwork} alt="" style={{ width: "100%", height: "100%", objectFit: "cover" }} /> : <MusicIcon s={sz / 3} />}
    </div>
  );
  const meta = (
    <div style={{ minWidth: 0 }}>
      <div style={{ fontSize: 13.5, fontWeight: 650, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{np.title}</div>
      <div className="w-sub" style={{ whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{np.artist}</div>
    </div>
  );
  const controls = (
    <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: size === "s" ? 6 : 14 }}>
      {size !== "s" && <IconButton onClick={() => ctl("previous")} title="Previous"><PrevIcon s={15} /></IconButton>}
      <IconButton big onClick={() => ctl("playpause")} title={playing ? "Pause" : "Play"}>{playing ? <PauseIcon s={16} /> : <PlayIcon s={16} />}</IconButton>
      <IconButton onClick={() => ctl("next")} title="Next"><NextIcon s={15} /></IconButton>
    </div>
  );
  const progress = (
    <div>
      <div style={{ height: 4, borderRadius: 4, background: "rgba(255,255,255,0.14)", overflow: "hidden" }}>
        <div style={{ height: "100%", width: `${np.duration ? (pos / np.duration) * 100 : 0}%`, background: "var(--w-accent, rgba(255,255,255,0.85))", borderRadius: 4, transition: "width 500ms linear" }} />
      </div>
      <div className="w-faint tnum" style={{ display: "flex", justifyContent: "space-between", fontSize: 10, marginTop: 3 }}>
        <span>{duration(pos)}</span><span>-{duration(np.duration - pos)}</span>
      </div>
    </div>
  );
  if (size === "s") return (
    <div style={{ display: "flex", flexDirection: "column", justifyContent: "space-between", height: "100%" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>{art(64)}{controls}</div>
      {meta}
    </div>
  );
  return (
    <div style={{ display: "flex", flexDirection: size === "l" ? "column" : "row", gap: 14, height: "100%", alignItems: size === "l" ? "stretch" : "center" }}>
      {art(size === "l" ? 200 : 118)}
      <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", justifyContent: "center", gap: 10 }}>
        {meta}{progress}{controls}
      </div>
    </div>
  );
}

/* ── Photo frame ────────────────────────────────────────── */

export function PhotoWidget({ config }: WidgetProps) {
  const minutes = Math.max(1, Number(config.interval) || 5);
  const { data, error } = usePoll<string>("photo_pick", { folder: config.folder ?? null, seed: null }, minutes * 60_000, [config.folder]);
  if (error && !data) return <WEmpty>{error}</WEmpty>;
  return (
    <div style={{ position: "absolute", inset: 0 }}>
      {data && (
        <img key={data.length + data.slice(-24)} src={data} alt="" className="anim-photo"
          style={{ position: "absolute", inset: 0, width: "100%", height: "100%", objectFit: "cover" }} />
      )}
    </div>
  );
}
