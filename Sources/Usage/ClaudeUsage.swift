import Combine
import Foundation

/// One of a plan's windows: how much of it is used and when it starts over.
struct UsageWindow: Equatable, Codable {
    let label: String
    /// 0–100.
    let percent: Double
    let resetsAt: Date?
}

/// What one account's plan reads right now.
struct AccountUsage: Identifiable, Equatable {
    enum Problem: Equatable {
        case signedOut
        case expired
        case unreachable
        /// The endpoint is refusing requests for now (HTTP 429).
        case rateLimited
    }

    let account: ClaudeAccount
    var plan: String?
    var windows: [UsageWindow] = []
    var problem: Problem?
    var readAt: Date?

    var id: String { account.id }
    /// The 5-hour window, the one the menu bar shows.
    var session: UsageWindow? { windows.first }
}

/// Reads how much of each Claude account's plan is used, from the sign-in
/// Claude Code already keeps in the login keychain.
///
/// Tokens are read through `/usr/bin/security`, which is on the items' access
/// list (Claude Code reads them the same way), so no keychain dialog appears
/// and none is remembered per build. They are never written or renewed here:
/// Claude Code renews a token whenever it runs in that account, and until then
/// the last reading stays with a note saying why it is not moving.
@MainActor
final class ClaudeUsage: ObservableObject {
    @Published private(set) var accounts: [AccountUsage] = []

    private var timer: Timer?
    private var inFlight = false
    nonisolated private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// The endpoint is rate limited; once every few minutes is what a person can see change anyway.
    private let interval: TimeInterval = 300

    /// Until when the endpoint is left alone after a 429, and how many came in
    /// a row. The limit is shared with everything else reading it on this Mac
    /// (Claude Code's own `/usage`, Leftover), so asking again at once only
    /// keeps it shut.
    private var holdOffUntil: Date?
    private var refusals = 0

    private let defaults: UserDefaults
    private static let cacheKey = "usageReadings"
    private static let holdOffKey = "usageHoldOffUntil"

    /// The last reading of each account is kept, so a launch shows it at once
    /// and a refused request costs nothing but freshness.
    private struct Saved: Codable {
        var plan: String?
        var windows: [UsageWindow]
        var readAt: Date
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        holdOffUntil = defaults.object(forKey: Self.holdOffKey) as? Date
        let saved = Self.loadSaved(defaults)
        // Every account is listed from the start, kept reading or not: an empty
        // list reads as "not signed in", which a refused request is not.
        let held = holdOffUntil.map { $0 > Date() } ?? false
        accounts = ClaudeAccount.discover().map { account in
            let reading = saved[account.id]
            return AccountUsage(account: account, plan: reading?.plan, windows: reading?.windows ?? [],
                                problem: held ? .rateLimited : nil, readAt: reading?.readAt)
        }
    }

    private static func loadSaved(_ defaults: UserDefaults) -> [String: Saved] {
        guard let data = defaults.data(forKey: cacheKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Saved].self, from: data)) ?? [:]
    }

    private func save() {
        var saved: [String: Saved] = [:]
        for usage in accounts {
            guard let readAt = usage.readAt, !usage.windows.isEmpty else { continue }
            saved[usage.id] = Saved(plan: usage.plan, windows: usage.windows, readAt: readAt)
        }
        defaults.set(try? JSONEncoder().encode(saved), forKey: Self.cacheKey)
    }

    /// Accounts that answered at least once: a `~/.claude-<name>` nobody ever
    /// signed into has nothing to show.
    var signedIn: [AccountUsage] {
        // The default account always shows; a `~/.claude-<name>` only once it has answered or been refused.
        accounts.filter { $0.account.slug == nil ? ($0.problem != .signedOut || !$0.windows.isEmpty) : ($0.problem == .rateLimited || !$0.windows.isEmpty) }
    }

    func start() {
        timer?.invalidate()
        refreshIfStale()   // a relaunch within the minute shows the kept reading instead of asking again
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Reads again unless a reading is under a minute old: called when the panel
    /// opens and when a turn ends, the moments a new figure is worth having.
    func refreshIfStale() {
        let oldest = accounts.compactMap(\.readAt).min()
        if let oldest, Date().timeIntervalSince(oldest) < 60, accounts.allSatisfy({ $0.problem == nil }) { return }
        refresh()
    }

    func refresh() {
        guard !inFlight else { return }
        // While the endpoint is being left alone, Claude Code itself is asked.
        let held = holdOffUntil.map { $0 > Date() } ?? false
        inFlight = true
        let discovered = ClaudeAccount.discover()
        Task {
            defer { inFlight = false }
            var next: [AccountUsage] = []
            var refused = false
            for account in discovered {
                var usage = accounts.first { $0.account == account } ?? AccountUsage(account: account)
                var outcome = held ? Outcome.failure(.rateLimited) : await Self.fetch(account)
                if case .failure(.rateLimited) = outcome {
                    refused = refused || !held
                    let windows = await ClaudeUsageCLI.read(account)
                    if !windows.isEmpty {
                        outcome = .success(plan: await Self.credentials(account)?.plan ?? usage.plan, windows: windows)
                    }
                }
                switch outcome {
                case .success(let plan, let windows):
                    usage.plan = plan
                    usage.windows = windows
                    usage.problem = nil
                    usage.readAt = Date()
                case .failure(let problem):
                    // The last good reading stays; the note says why it is not moving.
                    usage.problem = problem
                }
                next.append(usage)
            }
            accounts = next
            save()
            if held { return }   // nothing was asked of the endpoint; its hold stands
            if refused {
                refusals += 1
                // 5, 10, 20, then 30 minutes.
                holdOffUntil = Date().addingTimeInterval(min(30, 5 * pow(2, Double(refusals - 1))) * 60)
            } else {
                refusals = 0
                holdOffUntil = nil
            }
            defaults.set(holdOffUntil, forKey: Self.holdOffKey)
        }
    }

    /// Sample readings for the README screenshot (`--demo`); nothing is fetched.
    func loadDemo(_ accounts: [AccountUsage]) {
        self.accounts = accounts
    }

    // MARK: - Reading

    private struct Credentials {
        let token: String
        let expiresAt: Date?
        let plan: String?
    }

    private enum Outcome {
        case success(plan: String?, windows: [UsageWindow])
        case failure(AccountUsage.Problem)
    }

    /// The newest Claude sign-in among the account's keychain services. An item
    /// holding only MCP sign-ins (`mcpOAuth`) is not one.
    nonisolated private static func credentials(_ account: ClaudeAccount) async -> Credentials? {
        await Task.detached {
            account.keychainServices
                .compactMap(readItem(service:))
                .max { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }
        }.value
    }

    nonisolated private static func readItem(service: String) -> Credentials? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", NSUserName(), "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let plan = (oauth["subscriptionType"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return Credentials(token: token, expiresAt: expires, plan: plan)
    }

    nonisolated private static func fetch(_ account: ClaudeAccount) async -> Outcome {
        guard let credentials = await credentials(account) else { return .failure(.signedOut) }
        if let expires = credentials.expiresAt, expires < Date() { return .failure(.expired) }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return .failure(.unreachable)
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401, 403: return .failure(.expired)
        case 429: return .failure(.rateLimited)
        default: return .failure(.unreachable)
        }
        let windows = parse(data)
        return windows.isEmpty ? .failure(.unreachable) : .success(plan: credentials.plan, windows: windows)
    }

    /// The plan's windows in the order the response lists them: the session,
    /// the weekly window for all models, then each model-scoped weekly window
    /// under the model's own name (`Fable`), since the scope follows whichever
    /// model the plan meters separately.
    ///
    /// Older responses carry only the flat `five_hour` and `seven_day` blocks;
    /// those are read when `limits` is missing.
    nonisolated static func parse(_ data: Data) -> [UsageWindow] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let limits = json["limits"] as? [[String: Any]] {
            let windows = limits.compactMap(window(fromLimit:))
            if !windows.isEmpty { return windows }
        }
        let flat: [(key: String, label: String)] = [
            ("five_hour", L10n.t("Current session")),
            ("seven_day", L10n.t("All models")),
        ]
        return flat.compactMap { key, label in
            guard let window = json[key] as? [String: Any],
                  let percent = (window["utilization"] as? NSNumber)?.doubleValue
            else { return nil }
            return UsageWindow(label: label, percent: percent,
                               resetsAt: (window["resets_at"] as? String).flatMap(date(from:)))
        }
    }

    nonisolated private static func window(fromLimit limit: [String: Any]) -> UsageWindow? {
        guard let kind = limit["kind"] as? String,
              let percent = (limit["percent"] as? NSNumber)?.doubleValue
        else { return nil }
        let scope = limit["scope"] as? [String: Any]
        let model = ((scope?["model"] as? [String: Any])?["display_name"] as? String)?
            .trimmingCharacters(in: .whitespaces)
        let label: String
        switch kind {
        case "session": label = L10n.t("Current session")
        case "weekly_all": label = L10n.t("All models")
        case _ where model?.isEmpty == false: label = model!
        default: return nil   // a window this app does not know how to name
        }
        return UsageWindow(label: label, percent: percent,
                           resetsAt: (limit["resets_at"] as? String).flatMap(date(from:)))
    }

    nonisolated static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
