/**
 * Lightweight unit converter for the command palette.
 * Parses "<n> <unit> [to|in] <unit>" → formatted string, or null.
 * Supports length, mass, temperature, data, and time.
 */

type Unit = { aliases: string[]; toBase: (v: number) => number; fromBase: (v: number) => number; sym: string };

const LINEAR = (factor: number, sym: string, aliases: string[]): Unit => ({
  aliases, sym, toBase: v => v * factor, fromBase: v => v / factor,
});

const GROUPS: Record<string, Unit[]> = {
  length: [
    LINEAR(0.001, "km", ["km", "kilometer", "kilometers", "kilometre", "kilometres"]),
    LINEAR(1, "m", ["m", "meter", "meters", "metre", "metres"]),
    LINEAR(100, "cm", ["cm", "centimeter", "centimeters"]),
    LINEAR(1000, "mm", ["mm", "millimeter", "millimeters"]),
    LINEAR(1 / 1609.344, "mi", ["mi", "mile", "miles"]),
    LINEAR(1 / 0.9144, "yd", ["yd", "yard", "yards"]),
    LINEAR(1 / 0.3048, "ft", ["ft", "foot", "feet"]),
    LINEAR(1 / 0.0254, "in", ["in", "inch", "inches"]),
  ],
  mass: [
    LINEAR(0.001, "kg", ["kg", "kilo", "kilos", "kilogram", "kilograms"]),
    LINEAR(1, "g", ["g", "gram", "grams"]),
    LINEAR(1000, "mg", ["mg", "milligram", "milligrams"]),
    LINEAR(1 / 453.592, "lb", ["lb", "lbs", "pound", "pounds"]),
    LINEAR(1 / 28.3495, "oz", ["oz", "ounce", "ounces"]),
    LINEAR(0.000001, "t", ["t", "ton", "tons", "tonne", "tonnes"]),
  ],
  data: [
    LINEAR(1, "B", ["b", "byte", "bytes"]),
    LINEAR(1 / 1024, "KB", ["kb", "kilobyte", "kilobytes"]),
    LINEAR(1 / 1024 ** 2, "MB", ["mb", "megabyte", "megabytes"]),
    LINEAR(1 / 1024 ** 3, "GB", ["gb", "gigabyte", "gigabytes"]),
    LINEAR(1 / 1024 ** 4, "TB", ["tb", "terabyte", "terabytes"]),
  ],
  time: [
    LINEAR(1, "s", ["s", "sec", "secs", "second", "seconds"]),
    LINEAR(1 / 60, "min", ["min", "mins", "minute", "minutes"]),
    LINEAR(1 / 3600, "h", ["h", "hr", "hrs", "hour", "hours"]),
    LINEAR(1 / 86400, "d", ["d", "day", "days"]),
    LINEAR(1000, "ms", ["ms", "millisecond", "milliseconds"]),
  ],
};

// Temperature handled specially (affine, not linear).
const TEMP: Record<string, { aliases: string[]; sym: string; toC: (v: number) => number; fromC: (v: number) => number }> = {
  c: { aliases: ["c", "celsius", "centigrade"], sym: "°C", toC: v => v, fromC: v => v },
  f: { aliases: ["f", "fahrenheit"], sym: "°F", toC: v => (v - 32) * 5 / 9, fromC: v => v * 9 / 5 + 32 },
  k: { aliases: ["k", "kelvin"], sym: "K", toC: v => v - 273.15, fromC: v => v + 273.15 },
};

function findUnit(name: string): { group: string; unit: Unit } | null {
  const n = name.toLowerCase();
  for (const [group, units] of Object.entries(GROUPS)) {
    const u = units.find(u => u.aliases.includes(n));
    if (u) return { group, unit: u };
  }
  return null;
}
function findTemp(name: string) {
  const n = name.toLowerCase();
  return Object.values(TEMP).find(t => t.aliases.includes(n)) ?? null;
}

function fmt(n: number): string {
  if (Number.isInteger(n)) return n.toLocaleString();
  return parseFloat(n.toPrecision(6)).toLocaleString(undefined, { maximumFractionDigits: 6 });
}

export interface Conversion { value: string; from: string; to: string; }

export function tryConvert(input: string): Conversion | null {
  // e.g. "10 km to mi", "32f in c", "5 kg lb"
  const m = input.trim().toLowerCase().match(/^(-?\d+\.?\d*)\s*([a-z°]+)\s*(?:to|in|=)?\s*([a-z°]+)$/);
  if (!m) return null;
  const [, numStr, fromU, toU] = m;
  const num = parseFloat(numStr);
  if (!Number.isFinite(num)) return null;

  const tf = findTemp(fromU), tt = findTemp(toU);
  if (tf && tt) {
    const out = tt.fromC(tf.toC(num));
    return { value: `${fmt(out)} ${tt.sym}`, from: `${fmt(num)} ${tf.sym}`, to: tt.sym };
  }

  const f = findUnit(fromU), t = findUnit(toU);
  if (f && t && f.group === t.group) {
    const out = t.unit.fromBase(f.unit.toBase(num));
    return { value: `${fmt(out)} ${t.unit.sym}`, from: `${fmt(num)} ${f.unit.sym}`, to: t.unit.sym };
  }
  return null;
}
