/**
 * App brand colours for app-specific widgets (Spotify green on black, Apple
 * Music red, …). Known apps use their official colour; anything else gets a
 * colour sampled from its own icon, so every app widget feels like that app.
 */
import { createContext, useContext, useEffect, useState } from "react";
import { loadAppIcon } from "../components/icons";

export interface Brand {
  /** "r,g,b" — the signature colour. */
  rgb: string;
  /** Deep base under the glass (Spotify is near-black, most are a dark tint of rgb). */
  base?: string;
}

const KNOWN: Record<string, Brand> = {
  spotify:              { rgb: "30,215,96", base: "18,18,18" },
  music:                { rgb: "250,45,72" },
  "apple music":        { rgb: "250,45,72" },
  podcasts:             { rgb: "176,92,236" },
  whatsapp:             { rgb: "37,211,102", base: "11,20,26" },
  telegram:             { rgb: "42,171,238" },
  messages:             { rgb: "52,199,89" },
  slack:                { rgb: "236,178,46", base: "74,21,75" },
  discord:              { rgb: "88,101,242" },
  safari:               { rgb: "10,132,255" },
  "google chrome":      { rgb: "66,133,244" },
  "brave browser":      { rgb: "251,84,43" },
  arc:                  { rgb: "255,95,109" },
  firefox:              { rgb: "255,113,57" },
  "microsoft edge":     { rgb: "0,120,215" },
  "visual studio code": { rgb: "0,122,204" },
  cursor:               { rgb: "220,220,226", base: "20,20,22" },
  xcode:                { rgb: "20,126,251" },
  figma:                { rgb: "162,89,255" },
  notion:               { rgb: "235,235,235", base: "25,25,25" },
  obsidian:             { rgb: "124,58,237" },
  linear:               { rgb: "94,106,210" },
  raycast:              { rgb: "255,99,99" },
  zoom:                 { rgb: "45,140,255" },
  "zoom.us":            { rgb: "45,140,255" },
  "microsoft teams":    { rgb: "98,100,167" },
  mail:                 { rgb: "30,144,255" },
  notes:                { rgb: "255,214,10", base: "40,34,10" },
  calendar:             { rgb: "255,59,48" },
  reminders:            { rgb: "255,149,0" },
  photos:               { rgb: "255,159,10" },
  finder:               { rgb: "30,144,255" },
  "app store":          { rgb: "13,132,255" },
  terminal:             { rgb: "200,200,206", base: "18,18,20" },
  docker:               { rgb: "36,150,237" },
  "github desktop":     { rgb: "137,87,229" },
  youtube:              { rgb: "255,0,0" },
  netflix:              { rgb: "229,9,20", base: "16,16,16" },
  "1password":          { rgb: "26,140,255" },
  claude:               { rgb: "217,119,87" },
};

export function knownBrand(appName?: string): Brand | null {
  if (!appName) return null;
  return KNOWN[appName.toLowerCase().replace(/\.app$/, "").trim()] ?? null;
}

const sampled = new Map<string, Brand | null>();

/** Most characteristic saturated colour of an icon (hue histogram, saturation-weighted). */
export async function sampleIconBrand(dataUrl: string): Promise<Brand | null> {
  const img = new Image();
  img.src = dataUrl;
  await img.decode().catch(() => undefined);
  if (!img.width) return null;
  const n = 48;
  const c = document.createElement("canvas");
  c.width = c.height = n;
  const ctx = c.getContext("2d", { willReadFrequently: true });
  if (!ctx) return null;
  ctx.drawImage(img, 0, 0, n, n);
  const px = ctx.getImageData(0, 0, n, n).data;
  const buckets = new Array(24).fill(0).map(() => ({ w: 0, r: 0, g: 0, b: 0 }));
  for (let i = 0; i < px.length; i += 4) {
    const [r, g, b, a] = [px[i], px[i + 1], px[i + 2], px[i + 3]];
    if (a < 200) continue;
    const max = Math.max(r, g, b), min = Math.min(r, g, b);
    const sat = max === 0 ? 0 : (max - min) / max;
    if (sat < 0.35 || max < 60) continue; // ignore greys, white, black
    let h = 0;
    if (max === r) h = ((g - b) / (max - min)) % 6;
    else if (max === g) h = (b - r) / (max - min) + 2;
    else h = (r - g) / (max - min) + 4;
    const k = Math.floor((((h * 60) + 360) % 360) / 15);
    const w = sat * (max / 255);
    const bk = buckets[k];
    bk.w += w; bk.r += r * w; bk.g += g * w; bk.b += b * w;
  }
  const best = buckets.reduce((a, b) => (b.w > a.w ? b : a));
  if (best.w < 8) return null; // essentially monochrome icon
  return { rgb: `${Math.round(best.r / best.w)},${Math.round(best.g / best.w)},${Math.round(best.b / best.w)}` };
}

/** Brand for an app: known colour, else sampled from its icon (cached). */
export function useAppBrand(app?: { name?: string; path?: string } | null): Brand | null {
  const known = knownBrand(app?.name ?? app?.path?.split("/").pop());
  const [b, setB] = useState<Brand | null>(() => known ?? (app?.path ? sampled.get(app.path) ?? null : null));
  useEffect(() => {
    if (known) { setB(known); return; }
    const path = app?.path;
    if (!path) { setB(null); return; }
    if (sampled.has(path)) { setB(sampled.get(path) ?? null); return; }
    let alive = true;
    loadAppIcon(path).then(async data => {
      const br = data ? await sampleIconBrand(data) : null;
      sampled.set(path, br);
      if (alive) setB(br);
    });
    return () => { alive = false; };
  }, [known, app?.path]);
  return b;
}

/** Widgets report their brand to the card, which tints the glass. */
export const BrandContext = createContext<(b: Brand | null) => void>(() => {});

export function useCardBrand(b: Brand | null) {
  const set = useContext(BrandContext);
  useEffect(() => { set(b); return () => set(null); }, [set, b?.rgb, b?.base]);
}
