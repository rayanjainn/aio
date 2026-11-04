import Foundation

/// "10 km to mi", "32f in c", "5 kg lb" → "6.21371 mi". Length, mass, data, time, temperature.
enum UnitConverter {
    private struct Unit { let symbol: String; let aliases: [String]; let factor: Double }   // factor: units per base unit

    private static let groups: [String: [Unit]] = [
        "length": [
            Unit(symbol: "km", aliases: ["km", "kilometer", "kilometers", "kilometre", "kilometres"], factor: 0.001),
            Unit(symbol: "m", aliases: ["m", "meter", "meters", "metre", "metres"], factor: 1),
            Unit(symbol: "cm", aliases: ["cm", "centimeter", "centimeters"], factor: 100),
            Unit(symbol: "mm", aliases: ["mm", "millimeter", "millimeters"], factor: 1000),
            Unit(symbol: "mi", aliases: ["mi", "mile", "miles"], factor: 1 / 1609.344),
            Unit(symbol: "yd", aliases: ["yd", "yard", "yards"], factor: 1 / 0.9144),
            Unit(symbol: "ft", aliases: ["ft", "foot", "feet"], factor: 1 / 0.3048),
            Unit(symbol: "in", aliases: ["in", "inch", "inches"], factor: 1 / 0.0254),
        ],
        "mass": [
            Unit(symbol: "kg", aliases: ["kg", "kilo", "kilos", "kilogram", "kilograms"], factor: 0.001),
            Unit(symbol: "g", aliases: ["g", "gram", "grams"], factor: 1),
            Unit(symbol: "mg", aliases: ["mg", "milligram", "milligrams"], factor: 1000),
            Unit(symbol: "lb", aliases: ["lb", "lbs", "pound", "pounds"], factor: 1 / 453.592),
            Unit(symbol: "oz", aliases: ["oz", "ounce", "ounces"], factor: 1 / 28.3495),
            Unit(symbol: "t", aliases: ["t", "ton", "tons", "tonne", "tonnes"], factor: 0.000001),
        ],
        "data": [
            Unit(symbol: "B", aliases: ["b", "byte", "bytes"], factor: 1),
            Unit(symbol: "KB", aliases: ["kb", "kilobyte", "kilobytes"], factor: 1 / 1024),
            Unit(symbol: "MB", aliases: ["mb", "megabyte", "megabytes"], factor: 1 / pow(1024, 2)),
            Unit(symbol: "GB", aliases: ["gb", "gigabyte", "gigabytes"], factor: 1 / pow(1024, 3)),
            Unit(symbol: "TB", aliases: ["tb", "terabyte", "terabytes"], factor: 1 / pow(1024, 4)),
        ],
        "time": [
            Unit(symbol: "s", aliases: ["s", "sec", "secs", "second", "seconds"], factor: 1),
            Unit(symbol: "min", aliases: ["min", "mins", "minute", "minutes"], factor: 1 / 60),
            Unit(symbol: "h", aliases: ["h", "hr", "hrs", "hour", "hours"], factor: 1 / 3600),
            Unit(symbol: "d", aliases: ["d", "day", "days"], factor: 1 / 86400),
            Unit(symbol: "ms", aliases: ["ms", "millisecond", "milliseconds"], factor: 1000),
        ],
    ]

    private struct Temp { let symbol: String; let aliases: [String]; let toC: (Double) -> Double; let fromC: (Double) -> Double }
    private static let temps: [Temp] = [
        Temp(symbol: "°C", aliases: ["c", "celsius", "centigrade"], toC: { $0 }, fromC: { $0 }),
        Temp(symbol: "°F", aliases: ["f", "fahrenheit"], toC: { ($0 - 32) * 5 / 9 }, fromC: { $0 * 9 / 5 + 32 }),
        Temp(symbol: "K", aliases: ["k", "kelvin"], toC: { $0 - 273.15 }, fromC: { $0 + 273.15 }),
    ]

    /// Result like "6.21371 mi" (the pasteable value) and a label like "10 km → mi".
    static func convert(_ input: String) -> (value: String, label: String)? {
        let pattern = #"^(-?\d+\.?\d*)\s*([a-z°]+)\s*(?:to|in|=)?\s*([a-z°]+)$"#
        let text = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges == 4,
              let r1 = Range(m.range(at: 1), in: text), let r2 = Range(m.range(at: 2), in: text), let r3 = Range(m.range(at: 3), in: text),
              let number = Double(text[r1]) else { return nil }
        let from = String(text[r2]), to = String(text[r3])

        if let tf = temps.first(where: { $0.aliases.contains(from) }), let tt = temps.first(where: { $0.aliases.contains(to) }) {
            let out = tt.fromC(tf.toC(number))
            return ("\(format(out)) \(tt.symbol)", "\(format(number)) \(tf.symbol) → \(tt.symbol)")
        }
        for (_, units) in groups {
            if let f = units.first(where: { $0.aliases.contains(from) }), let t = units.first(where: { $0.aliases.contains(to) }) {
                let out = number / f.factor * t.factor
                return ("\(format(out)) \(t.symbol)", "\(format(number)) \(f.symbol) → \(t.symbol)")
            }
        }
        return nil
    }

    private static func format(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        let f = NumberFormatter()
        f.maximumSignificantDigits = 6
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}

enum EmojiSearch {
    static func search(_ query: String, limit: Int = 8) -> [(c: String, name: String)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return emojiSet.prefix(limit).map { ($0.c, $0.name) } }
        let words = q.split(separator: " ").map(String.init)
        var scored: [(Int, (c: String, name: String))] = []
        for e in emojiSet {
            let hay = "\(e.name) \(e.kw)"
            var score = 0
            if e.name == q { score = 100 }
            else if e.name.hasPrefix(q) { score = 80 }
            else if e.name.contains(q) { score = 60 }
            else if hay.contains(q) { score = 40 }
            else if words.allSatisfy({ hay.contains($0) }) { score = 20 }
            if score > 0 { scored.append((score, (e.c, e.name))) }
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map { $0.1 }
    }
}
