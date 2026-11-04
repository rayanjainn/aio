import XCTest
import Carbon.HIToolbox
@testable import Cortex

final class CalculatorTests: XCTestCase {
    func testBasicArithmetic() {
        XCTAssertEqual(Calculator.evaluate("12*(3+4)"), "84")
        XCTAssertEqual(Calculator.evaluate("2^10"), "1024")
        XCTAssertEqual(Calculator.evaluate("10/4"), "2.5")
        XCTAssertEqual(Calculator.evaluate("-3 + 5"), "2")
        XCTAssertEqual(Calculator.evaluate("sqrt(81)"), "9")
        XCTAssertEqual(Calculator.evaluate("1,000 + 1"), "1001")
    }

    func testRejectsNonMath() {
        XCTAssertNil(Calculator.evaluate("safari"))
        XCTAssertNil(Calculator.evaluate("42"))          // a bare number isn't an expression
        XCTAssertNil(Calculator.evaluate("1/0"))
        XCTAssertNil(Calculator.evaluate("(1+"))
        XCTAssertNil(Calculator.evaluate("2 + abc"))
    }
}

final class ConverterTests: XCTestCase {
    func testLengthMassTemperature() {
        XCTAssertEqual(UnitConverter.convert("10 km to mi")?.value, "6.21371 mi")
        XCTAssertEqual(UnitConverter.convert("32f in c")?.value, "0 °C")
        XCTAssertEqual(UnitConverter.convert("1 kg to lb")?.value, "2.20462 lb")
        XCTAssertEqual(UnitConverter.convert("1 gb to mb")?.value, "1024 MB")
    }

    func testRejectsMismatchedUnits() {
        XCTAssertNil(UnitConverter.convert("5 kg to km"))
        XCTAssertNil(UnitConverter.convert("hello"))
    }

    func testCurrencyParsing() {
        let c = CurrencyService.parse("100 usd to inr")
        XCTAssertEqual(c?.amount, 100)
        XCTAssertEqual(c?.from, "USD")
        XCTAssertEqual(c?.to, "INR")
        XCTAssertNil(CurrencyService.parse("100 to inr"))
    }

    func testEmojiSearch() {
        XCTAssertEqual(EmojiSearch.search("fire").first?.c, "🔥")
        XCTAssertTrue(EmojiSearch.search("zzzzzz").isEmpty)
    }
}

final class ShortcutTests: XCTestCase {
    func testParsesAccelerators() {
        let k = Accelerator.parse("Control+Alt+KeyU")
        XCTAssertEqual(k?.key, UInt32(kVK_ANSI_U))
        XCTAssertEqual(k?.modifiers, UInt32(controlKey) | UInt32(optionKey))
        XCTAssertEqual(Accelerator.parse("CommandOrControl+K")?.modifiers, UInt32(cmdKey))
        XCTAssertEqual(Accelerator.parse("Alt+Tab")?.key, UInt32(kVK_Tab))
        XCTAssertEqual(Accelerator.parse("Control+Alt+ArrowLeft")?.key, UInt32(kVK_LeftArrow))
        XCTAssertNil(Accelerator.parse("Control+Alt+Nonsense"))
    }

    func testDisplayText() {
        XCTAssertEqual(Accelerator.display("Control+Alt+KeyK"), "⌃⌥K")
        XCTAssertEqual(Accelerator.display("CommandOrControl+Shift+KeyP"), "⌘⇧P")
        XCTAssertEqual(Accelerator.display(""), "Not set")
    }

    func testEveryDefaultShortcutParses() {
        for entry in ShortcutTable.all where !entry.accel.isEmpty {
            XCTAssertNotNil(Accelerator.parse(entry.accel), "\(entry.id): \(entry.accel)")
        }
    }

    func testNoTwoDefaultsCollide() {
        var seen: [String: String] = [:]
        for entry in ShortcutTable.all where !entry.accel.isEmpty {
            if let other = seen[entry.accel] { XCTFail("\(entry.id) and \(other) share \(entry.accel)") }
            seen[entry.accel] = entry.id
        }
    }
}

final class WindowGeometryTests: XCTestCase {
    private let area = CGRect(x: 0, y: 25, width: 1600, height: 900)
    private let current = CGRect(x: 100, y: 100, width: 800, height: 600)

    func testHalvesAndThirds() {
        XCTAssertEqual(WindowManager.rect(for: "left", in: area, current: current), CGRect(x: 0, y: 25, width: 800, height: 900))
        XCTAssertEqual(WindowManager.rect(for: "right", in: area, current: current), CGRect(x: 800, y: 25, width: 800, height: 900))
        XCTAssertEqual(WindowManager.rect(for: "topLeft", in: area, current: current), CGRect(x: 0, y: 25, width: 800, height: 450))
        XCTAssertEqual(WindowManager.rect(for: "bottomRight", in: area, current: current), CGRect(x: 800, y: 475, width: 800, height: 450))
        XCTAssertEqual(WindowManager.rect(for: "centerThird", in: area, current: current)?.width ?? 0, 1600.0 / 3, accuracy: 0.001)
        XCTAssertEqual(WindowManager.rect(for: "max", in: area, current: current), area)
    }

    func testCenterKeepsSizeAndAlmostMaxInsets() {
        let c = WindowManager.rect(for: "center", in: area, current: current)
        XCTAssertEqual(c?.size, current.size)
        XCTAssertEqual(c?.midX ?? 0, area.midX, accuracy: 0.001)
        XCTAssertEqual(WindowManager.rect(for: "almostMax", in: area, current: current)?.width ?? 0, 1440, accuracy: 0.001)
        XCTAssertNil(WindowManager.rect(for: "bogus", in: area, current: current))
    }
}

final class UpdateTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("v0.3.0-native.5", than: "v0.3.0-native.4"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.3.0-native.4", than: "v0.3.0-native.4"))
        XCTAssertTrue(UpdateChecker.isNewer("v0.4.0", than: "v0.3.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.1", than: "v0.3.0-native.1"))
    }
}

final class LyricsTests: XCTestCase {
    func testParsesTimedLines() {
        let lines = LyricsService.parse("[00:12.50] Hello\n[01:02.00] World\nnot a lyric\n[00:30.00]")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].time, 12.5, accuracy: 0.001)
        XCTAssertEqual(lines[0].text, "Hello")
        XCTAssertEqual(lines[2].text, "")
        XCTAssertEqual(lines.map(\.time), lines.map(\.time).sorted())
    }
}

final class CalendarLinkTests: XCTestCase {
    func testFindsMeetingLinks() {
        XCTAssertEqual(CalendarService.joinURL(in: [nil, "Join: https://meet.google.com/abc-defg-hij now"])?.host, "meet.google.com")
        XCTAssertEqual(CalendarService.joinURL(in: ["https://acme.zoom.us/j/123?pwd=x"])?.host, "acme.zoom.us")
        XCTAssertNil(CalendarService.joinURL(in: ["Room 4B", "bring snacks"]))
    }
}

final class PrettyModelTests: XCTestCase {
    func testClaudeModelNames() {
        XCTAssertEqual(CodingUsageService.prettyModel("claude-sonnet-4-5-20250929"), "Sonnet 4.5")
        XCTAssertEqual(CodingUsageService.prettyModel("gpt-5-codex"), "gpt-5-codex")
        XCTAssertEqual(tokenString(1_250_000), "1.2M")
        XCTAssertEqual(tokenString(950), "950")
    }
}

final class PaletteCurationTests: XCTestCase {
    private func result(_ plugin: String, _ title: String, url: String? = nil) -> EngineResult {
        EngineResult(id: UUID().uuidString, pluginId: plugin, sourceType: "unknown", title: title, subtitle: nil, content: nil,
                     path: nil, url: url, score: 1, action: "open", metadata: nil)
    }

    func testEmptyQueryShowsAppsNotCommitsOrFileURLs() {
        let input = [result("git", "a1b2 — fix"), result("browser", "x", url: "file:///tmp/a.svg"), result("apps", "Safari"), result("commands", "Sleep")]
        let out = PaletteModel.curate(input, forEmptyQuery: true)
        XCTAssertEqual(out.map(\.title), ["Safari", "Sleep"])
    }

    func testGroupingKeepsFirstAppearanceOrder() {
        let rows = ["Files", "Applications", "Files", "Git"].enumerated().map { i, s in
            PaletteRow(id: "\(i)", title: "t\(i)", subtitle: "", symbol: "doc", iconPath: nil, tag: "", kind: .copy("x"), section: s)
        }
        XCTAssertEqual(PaletteModel.grouped(rows).map(\.section), ["Files", "Files", "Applications", "Git"])
    }

    func testURLNormalisation() {
        XCTAssertEqual(PaletteModel.normalizedURL("example.com"), "https://example.com")
        XCTAssertEqual(PaletteModel.normalizedURL("http://a.b/c"), "http://a.b/c")
        XCTAssertNil(PaletteModel.normalizedURL("notaurl"))
    }
}
