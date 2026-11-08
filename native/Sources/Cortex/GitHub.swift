import AppKit
import SwiftUI

/// Tokens for outside services. Stored in ~/.cortex/native/connections.json (readable by you only) and never exported.
struct Connections: Codable, Equatable {
    var githubToken = ""

    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex/native/connections.json")
    }

    static func load() -> Connections {
        guard let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Connections.self, from: d) else { return Connections() }
        return c
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? JSONEncoder().encode(self) else { return }
        try? d.write(to: Self.url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }
}

struct GHItem: Identifiable, Equatable {
    let id: String
    let title: String
    let repo: String
    let number: Int
    let url: URL
    let kind: String        // "pr", "issue", "review", or a notification reason
    let updated: Date?
}

/// Your GitHub at a glance: notifications, pull requests (yours and the ones waiting for your review),
/// issues assigned to you, and the contribution calendar. Uses a personal access token.
@MainActor
final class GitHubService: ObservableObject {
    static let shared = GitHubService()

    @Published private(set) var login = ""
    @Published private(set) var name = ""
    @Published private(set) var avatar: NSImage?
    @Published private(set) var notifications: [GHItem] = []
    @Published private(set) var myPRs: [GHItem] = []
    @Published private(set) var reviewRequests: [GHItem] = []
    @Published private(set) var assigned: [GHItem] = []
    /// Contribution levels 0…4, oldest week first, seven days per week.
    @Published private(set) var weeks: [[Int]] = []
    @Published private(set) var totalContributions = 0
    @Published private(set) var status = "Not connected"
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var notificationsAllowed = true

    private var timer: Timer?
    private var loading = false

    var connected: Bool { !login.isEmpty }
    var token: String { Connections.load().githubToken }

    func start() {
        guard !token.isEmpty else { status = "Not connected"; return }
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in GitHubService.shared.refresh() }
        }
    }

    func setToken(_ value: String) {
        var c = Connections.load()
        c.githubToken = value.trimmingCharacters(in: .whitespacesAndNewlines)
        c.save()
        if c.githubToken.isEmpty { disconnect() } else { start() }
    }

    func disconnect() {
        timer?.invalidate(); timer = nil
        login = ""; name = ""; avatar = nil
        notifications = []; myPRs = []; reviewRequests = []; assigned = []; weeks = []; totalContributions = 0
        status = "Not connected"
    }

    func refresh() {
        let token = self.token
        guard !token.isEmpty, !loading else { return }
        loading = true
        status = "Updating…"
        Task {
            defer { loading = false }
            do {
                let user = try await Self.json("/user", token: token) as? [String: Any] ?? [:]
                login = user["login"] as? String ?? ""
                name = user["name"] as? String ?? ""
                if let a = user["avatar_url"] as? String, let u = URL(string: a + "&s=96"), avatar == nil {
                    if let (d, _) = try? await URLSession.shared.data(from: u) { avatar = NSImage(data: d) }
                }
                async let prs = Self.search("is:open is:pr author:@me archived:false", token: token, kind: "pr")
                async let reviews = Self.search("is:open is:pr review-requested:@me archived:false", token: token, kind: "review")
                async let issues = Self.search("is:open is:issue assignee:@me archived:false", token: token, kind: "issue")
                async let cal = Self.contributions(token: token)
                async let notes = Self.notifications(token: token)
                myPRs = (try? await prs) ?? []
                reviewRequests = (try? await reviews) ?? []
                assigned = (try? await issues) ?? []
                if let c = try? await cal { weeks = c.weeks; totalContributions = c.total }
                if let n = try? await notes { notifications = n; notificationsAllowed = true } else { notificationsAllowed = false }
                lastUpdated = Date()
                status = "Signed in as \(login)"
            } catch {
                status = "Couldn't reach GitHub: \(error.localizedDescription)"
                if (error as NSError).code == 401 { login = "" }
            }
        }
    }

    // MARK: API

    nonisolated private static func request(_ path: String, token: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        r.httpMethod = method
        r.httpBody = body
        r.timeoutInterval = 15
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("Cortex-macOS", forHTTPHeaderField: "User-Agent")
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    nonisolated static func json(_ path: String, token: String, method: String = "GET", body: Data? = nil) async throws -> Any {
        let (data, resp) = try await URLSession.shared.data(for: request(path, token: token, method: method, body: body))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String ?? "HTTP \(code)"
            throw NSError(domain: "GitHub", code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    nonisolated private static func search(_ q: String, token: String, kind: String) async throws -> [GHItem] {
        let query = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.replacingOccurrences(of: "+", with: "%2B") ?? q
        let obj = try await json("/search/issues?q=\(query)&sort=updated&per_page=15", token: token) as? [String: Any]
        return ((obj?["items"] as? [[String: Any]]) ?? []).compactMap { i in
            guard let html = (i["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            let repo = (i["repository_url"] as? String).map { $0.components(separatedBy: "/repos/").last ?? $0 } ?? ""
            return GHItem(id: "\(kind):\(html.absoluteString)", title: i["title"] as? String ?? "", repo: repo,
                          number: i["number"] as? Int ?? 0, url: html, kind: kind, updated: parseDate(i["updated_at"] as? String))
        }
    }

    nonisolated private static func notifications(token: String) async throws -> [GHItem] {
        let list = try await json("/notifications?per_page=30", token: token) as? [[String: Any]] ?? []
        return list.compactMap { n in
            let subject = n["subject"] as? [String: Any] ?? [:]
            let repo = (n["repository"] as? [String: Any])?["full_name"] as? String ?? ""
            let api = subject["url"] as? String
            let url = api.flatMap(htmlURL(fromAPI:)) ?? URL(string: "https://github.com/notifications")!
            return GHItem(id: "n:\(n["id"] as? String ?? UUID().uuidString)", title: subject["title"] as? String ?? "", repo: repo,
                          number: 0, url: url, kind: (n["reason"] as? String) ?? "notification", updated: parseDate(n["updated_at"] as? String))
        }
    }

    nonisolated private static func contributions(token: String) async throws -> (weeks: [[Int]], total: Int) {
        let q = "query{viewer{contributionsCollection{contributionCalendar{totalContributions weeks{contributionDays{contributionLevel}}}}}}"
        let body = try JSONSerialization.data(withJSONObject: ["query": q])
        let obj = try await json("/graphql", token: token, method: "POST", body: body) as? [String: Any]
        let cal = (((obj?["data"] as? [String: Any])?["viewer"] as? [String: Any])?["contributionsCollection"] as? [String: Any])?["contributionCalendar"] as? [String: Any]
        let weeks = ((cal?["weeks"] as? [[String: Any]]) ?? []).map { w in
            ((w["contributionDays"] as? [[String: Any]]) ?? []).map { level($0["contributionLevel"] as? String ?? "") }
        }
        return (weeks, cal?["totalContributions"] as? Int ?? 0)
    }

    // MARK: pure helpers (tested)

    /// api.github.com/repos/o/r/pulls/12 → github.com/o/r/pull/12 (issues, commits and releases likewise).
    nonisolated static func htmlURL(fromAPI api: String) -> URL? {
        guard let range = api.range(of: "/repos/") else { return nil }
        var path = String(api[range.upperBound...])
        path = path.replacingOccurrences(of: "/pulls/", with: "/pull/").replacingOccurrences(of: "/commits/", with: "/commit/")
        if path.contains("/releases/") { path = (path.components(separatedBy: "/releases/").first ?? path) + "/releases" }
        return URL(string: "https://github.com/" + path)
    }

    nonisolated static func level(_ s: String) -> Int {
        switch s {
        case "FIRST_QUARTILE": 1
        case "SECOND_QUARTILE": 2
        case "THIRD_QUARTILE": 3
        case "FOURTH_QUARTILE": 4
        default: 0
        }
    }

    nonisolated static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }
}

// MARK: Views

/// The contribution calendar in white on glass: brighter squares for busier days.
struct ContributionGrid: View {
    let weeks: [[Int]]
    let cell: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: cell * 0.28) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: cell * 0.28) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, lvl in
                        RoundedRectangle(cornerRadius: cell * 0.28, style: .continuous)
                            .fill(Color.white.opacity([0.08, 0.28, 0.48, 0.7, 0.95][min(4, max(0, lvl))]))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
    }
}

struct GitHubWidget: View {
    let size: WidgetSize
    @ObservedObject private var gh = GitHubService.shared

    var body: some View {
        Group {
            if !gh.connected {
                VStack(spacing: 8) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
                    Text(gh.token.isEmpty ? "Connect GitHub in Settings → Connections" : gh.status)
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    if size != .small {
                        GeometryReader { geo in
                            let cols = max(8, Int((geo.size.width + 3) / 12))
                            ContributionGrid(weeks: Array(gh.weeks.suffix(cols)), cell: 9)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .frame(height: 9 * 7 + 2.5 * 6)
                    }
                    counts
                    if size == .large { list }
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear { gh.start() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let a = gh.avatar { Image(nsImage: a).resizable().frame(width: 22, height: 22).clipShape(Circle()) }
            VStack(alignment: .leading, spacing: 0) {
                Text(gh.login).font(.system(size: 12, weight: .semibold))
                if size != .small { Text("\(gh.totalContributions) contributions this year").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Spacer()
            Button { gh.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Refresh")
        }
    }

    private var counts: some View {
        HStack(spacing: 6) {
            stat("bell", gh.notifications.count, "Inbox", URL(string: "https://github.com/notifications")!)
            stat("eye", gh.reviewRequests.count, "Review", URL(string: "https://github.com/pulls/review-requested")!)
            stat("arrow.triangle.pull", gh.myPRs.count, "PRs", URL(string: "https://github.com/pulls")!)
            if size != .small { stat("smallcircle.filled.circle", gh.assigned.count, "Issues", URL(string: "https://github.com/issues/assigned")!) }
        }
    }

    private func stat(_ symbol: String, _ n: Int, _ label: String, _ url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                    Text("\(n)").font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                }
                Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array((gh.reviewRequests + gh.myPRs + gh.assigned).prefix(5))) { item in
                Button { NSWorkspace.shared.open(item.url) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.kind == "review" ? "eye" : item.kind == "pr" ? "arrow.triangle.pull" : "smallcircle.filled.circle")
                            .font(.system(size: 9)).frame(width: 12)
                        Text(item.title).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(item.repo.components(separatedBy: "/").last ?? "").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Dock tile: unread notifications and reviews waiting on you. Click opens GitHub notifications.
struct GitHubDockWidget: View {
    let size: CGFloat
    @ObservedObject private var gh = GitHubService.shared

    var body: some View {
        Button { NSWorkspace.shared.open(URL(string: gh.reviewRequests.isEmpty ? "https://github.com/notifications" : "https://github.com/pulls/review-requested")!) } label: {
            VStack(spacing: 2) {
                Image(systemName: "bell.fill").font(.system(size: size * 0.3, weight: .medium))
                    .symbolEffect(.bounce, value: gh.notifications.count)
                    .overlay(alignment: .topTrailing) {
                        if gh.connected, !gh.notifications.isEmpty {
                            Text(gh.notifications.count > 99 ? "99+" : "\(gh.notifications.count)")
                                .font(.system(size: size * 0.17, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                                .padding(.horizontal, 3).frame(minWidth: size * 0.3, minHeight: size * 0.3)
                                .background(Capsule().fill(Color(red: 1, green: 0.27, blue: 0.23)))
                                .fixedSize()
                                .offset(x: size * 0.2, y: -size * 0.12)
                        }
                    }
                Text(gh.connected ? (gh.reviewRequests.isEmpty ? "GitHub" : "\(gh.reviewRequests.count) review\(gh.reviewRequests.count == 1 ? "" : "s")") : "Connect")
                    .font(.system(size: size * 0.16, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(.primary.opacity(0.75))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(gh.connected ? "\(gh.notifications.count) notifications · \(gh.reviewRequests.count) reviews waiting" : "Connect GitHub in Settings → Connections")
        .onAppear { gh.start() }
    }
}

// MARK: Settings

struct ConnectionsPane: View {
    @ObservedObject private var gh = GitHubService.shared
    @State private var token = Connections.load().githubToken
    @State private var aiResult = ""
    @State private var aiTesting = false
    @State private var tabsResult = ""
    @State private var engineResult = ""
    let engine: EngineClient

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    if let a = gh.avatar { Image(nsImage: a).resizable().frame(width: 32, height: 32).clipShape(Circle()) }
                    else { Image(systemName: "chevron.left.forwardslash.chevron.right").frame(width: 32) }
                    VStack(alignment: .leading) {
                        Text("GitHub").font(.headline)
                        Text(gh.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if gh.connected { Button("Refresh") { gh.refresh() } }
                }
                SecureField("Personal access token", text: $token)
                HStack {
                    Button(gh.connected ? "Save" : "Connect") { gh.setToken(token) }.buttonStyle(.borderedProminent)
                    if gh.connected { Button("Disconnect") { token = ""; gh.setToken("") } }
                    Spacer()
                    Button("Create a token…") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/settings/tokens/new?scopes=repo,notifications,read:user&description=Cortex")!)
                    }
                }
                Text("A classic token with repo, notifications and read:user is enough. It stays in ~/.cortex/native/connections.json, readable only by you, and is never exported.")
                    .font(.caption).foregroundStyle(.secondary)
                if gh.connected {
                    LabeledContent("Notifications", value: gh.notificationsAllowed ? "\(gh.notifications.count) unread" : "token can't read notifications")
                    LabeledContent("Reviews waiting", value: "\(gh.reviewRequests.count)")
                    LabeledContent("Your open PRs", value: "\(gh.myPRs.count)")
                    LabeledContent("Assigned issues", value: "\(gh.assigned.count)")
                    LabeledContent("Contributions this year", value: "\(gh.totalContributions)")
                    Text("Add the GitHub widget from the menu bar (Add Widget…) or the Dock (right-click → Add widget), or type  gh  in ⌘K.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("AI") {
                LabeledContent("Provider", value: aiProviderName)
                HStack {
                    Button(aiTesting ? "Testing…" : "Test connection") { testAI() }.disabled(aiTesting)
                    Text(aiResult).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("Change the provider and keys in the AI section.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Browser tabs") {
                HStack {
                    Button("Test") {
                        tabsResult = "Asking your browsers…"
                        Task {
                            let tabs = await Task.detached { BrowserTabs.list() }.value
                            let by = Dictionary(grouping: tabs, by: \.bundle).map { key, list in
                                let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? key
                                return "\(name): \(list.count)"
                            }.sorted()
                            let errors = BrowserTabs.lastErrors.map { "\($0.key): \($0.value)" }.sorted()
                            tabsResult = (tabs.isEmpty ? "No tabs found — open a browser and allow Automation for it (Privacy & Permissions)." : "\(tabs.count) tabs · " + by.joined(separator: ", "))
                                + (errors.isEmpty ? "" : "\n" + errors.joined(separator: "\n"))
                        }
                    }
                    Text(tabsResult).font(.caption).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
                }
                Text("Safari, Chrome, Brave, Arc and Edge. Each browser asks once for Automation; type  tab  in ⌘K to search them.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Search engine") {
                HStack {
                    Button("Test") {
                        Task {
                            let start = Date()
                            if let r = try? await engine.call("ping") { engineResult = "Running · answered in \(Int(Date().timeIntervalSince(start) * 1000)) ms · \(String(decoding: r, as: UTF8.self).prefix(60))" }
                            else { engineResult = "Not responding" }
                        }
                    }
                    Text(engineResult).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var aiProviderName: String {
        switch AISettings.load().provider {
        case "ollamaCloud": "Ollama Cloud"
        case "openai": "OpenAI-compatible"
        default: "Ollama on this Mac"
        }
    }

    private func testAI() {
        aiTesting = true
        aiResult = ""
        Task {
            let start = Date()
            var text = ""
            do {
                for try await chunk in AIChat.stream("Reply with exactly: ok") {
                    text += chunk
                    if text.count > 40 { break }
                }
                aiResult = text.isEmpty ? "Connected, but the model sent nothing back."
                    : "Works · \(Int(Date().timeIntervalSince(start) * 1000)) ms · “\(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))”"
            } catch {
                aiResult = "Failed: \(error.localizedDescription)"
            }
            aiTesting = false
        }
    }
}
