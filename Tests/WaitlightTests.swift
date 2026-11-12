import XCTest
@testable import Waitlight

@MainActor
final class SessionBoardTests: XCTestCase {
    private let account = ClaudeAccount(slug: nil, directory: URL(fileURLWithPath: "/tmp/.claude"))

    private func tracked(_ state: AgentSession.State, at seconds: TimeInterval, waitingFor: String? = nil) -> ClaudeSessionMonitor.Tracked {
        let session = AgentSession(id: "claude.1", name: "app", detail: "Terminal · app", state: state,
                                   waitingFor: waitingFor, since: Date(timeIntervalSince1970: seconds), processID: 1)
        return .init(session: session, account: account, cwd: "/tmp/app")
    }

    func testBusyThenIdleIsDoneAndAnnouncedOnce() {
        let board = SessionBoard(monitor: ClaudeSessionMonitor(discover: { [] }))
        var done = 0
        board.onDone = { _ in done += 1 }
        board.apply([tracked(.busy, at: 10)])
        board.apply([tracked(.idle, at: 20)])
        XCTAssertEqual(board.rows.first?.phase, .done)
        XCTAssertEqual(board.rows.first?.since, Date(timeIntervalSince1970: 20))
        board.apply([tracked(.idle, at: 20)])
        XCTAssertEqual(done, 1)
    }

    func testIdleAtLaunchIsNotDone() {
        let board = SessionBoard(monitor: ClaudeSessionMonitor(discover: { [] }))
        board.apply([tracked(.idle, at: 5)])
        XCTAssertEqual(board.rows.first?.phase, .idle)
    }

    func testIdleAtLaunchAfterARecentTurnIsDoneAndNotAnnounced() {
        let board = SessionBoard(monitor: ClaudeSessionMonitor(discover: { [] }))
        var done = 0
        board.onDone = { _ in done += 1 }
        let ended = Date().addingTimeInterval(-300)
        let session = AgentSession(id: "claude.1", name: "app", detail: "Terminal · app", state: .idle,
                                   waitingFor: nil, since: ended, processID: 1)
        board.apply([.init(session: session, account: account, cwd: "/tmp/app",
                           startedAt: ended.addingTimeInterval(-600))])
        XCTAssertEqual(board.rows.first?.phase, .done)
        XCTAssertEqual(done, 0)

        // Opened and never used: idle since it started.
        let unused = SessionBoard(monitor: ClaudeSessionMonitor(discover: { [] }))
        unused.apply([.init(session: session, account: account, cwd: "/tmp/app", startedAt: ended)])
        XCTAssertEqual(unused.rows.first?.phase, .idle)
    }

    func testWaitingIsAnnouncedOnEntryOnly() {
        let board = SessionBoard(monitor: ClaudeSessionMonitor(discover: { [] }))
        var waits: [String?] = []
        board.onWaiting = { waits.append($0.session.waitingFor) }
        board.apply([tracked(.busy, at: 1)])
        board.apply([tracked(.waiting, at: 2, waitingFor: "Bash")])
        board.apply([tracked(.waiting, at: 2, waitingFor: "Bash")])
        XCTAssertEqual(waits, ["Bash"])
        XCTAssertEqual(board.waiting.count, 1)
    }

    func testWaitingSortsFirst() {
        let board = SessionBoard(monitor: ClaudeSessionMonitor(discover: { [] }))
        let other = AgentSession(id: "claude.2", name: "b", detail: "Terminal · b", state: .busy,
                                 waitingFor: nil, since: Date(timeIntervalSince1970: 1), processID: 2)
        board.apply([.init(session: other, account: account, cwd: "/tmp/b"), tracked(.waiting, at: 9)])
        XCTAssertEqual(board.rows.map(\.phase), [.waiting, .working])
    }
}

final class ReadingTests: XCTestCase {
    func testRecordReadsWaiting() {
        let record = ClaudeSessionRecord(json: ["pid": 42, "cwd": "/Users/x/app", "status": "waiting",
                                                "waitingFor": "approve Bash", "statusUpdatedAt": 1_000_000,
                                                "entrypoint": "cli"])
        XCTAssertEqual(record?.session.state, .waiting)
        XCTAssertEqual(record?.session.waitingFor, "approve Bash")
        XCTAssertTrue(record?.reportsStatus == true)
    }

    func testUsageParse() {
        let json = """
        {"five_hour":{"utilization":11.0,"resets_at":"2026-11-12T23:29:59.941762+00:00"},
         "seven_day":{"utilization":47.0,"resets_at":"2026-11-14T03:59:58+00:00"},
         "seven_day_opus":null}
        """.data(using: .utf8)!
        let windows = ClaudeUsage.parse(json)
        XCTAssertEqual(windows.map(\.percent), [11, 47])
        XCTAssertNotNil(windows[0].resetsAt)
        XCTAssertNotNil(windows[1].resetsAt)
    }

    func testUsageParseReadsScopedModelWindow() {
        let json = """
        {"five_hour":{"utilization":18.0},"seven_day":{"utilization":48.0},
         "limits":[
          {"kind":"session","percent":18,"resets_at":"2026-11-12T23:30:00.151751+00:00","scope":null},
          {"kind":"weekly_all","percent":48,"resets_at":"2026-11-14T03:59:59.151777+00:00","scope":null},
          {"kind":"weekly_scoped","percent":41,"resets_at":"2026-11-14T04:00:00+00:00",
           "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}},
          {"kind":"something_new","percent":5,"scope":null}]}
        """.data(using: .utf8)!
        let windows = ClaudeUsage.parse(json)
        XCTAssertEqual(windows.map(\.percent), [18, 48, 41])
        XCTAssertEqual(windows.last?.label, "Fable")
    }

    func testDurationPastADayReadsInDays() {
        XCTAssertEqual(L10n.duration(31 * 3600 + 22 * 60).filter(\.isNumber), "17")   // 1 d 7 h
        XCTAssertEqual(L10n.duration(48 * 3600).filter(\.isNumber), "2")
    }

    func testUsageCLIParse() {
        let text = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 50% used · resets Nov 13 at 2:30am (Europe/Istanbul)
        Current week (all models): 51% used · resets Nov 14 at 6:59am (Europe/Istanbul)
        Current week (Fable): 48% used · resets Nov 14 at 7am (Europe/Istanbul)

        Last 24h · 562 requests · 9 sessions
          53%  Start fresh when you switch tasks · run /clear
        """
        let now = ISO8601DateFormatter().date(from: "2026-11-12T21:05:00Z")!
        let windows = ClaudeUsageCLI.parse(text, now: now)
        XCTAssertEqual(windows.map(\.percent), [50, 51, 48])
        XCTAssertEqual(windows.last?.label, "Fable")
        XCTAssertEqual(windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-11-12T23:30:00Z"))
        XCTAssertEqual(windows[2].resetsAt, ISO8601DateFormatter().date(from: "2026-11-14T04:00:00Z"))
    }

    func testKeychainSuffixMatchesClaudeCode() {
        // Claude Code's rule: the first eight hex digits of SHA-256 of the path.
        XCTAssertEqual(ClaudeAccount.suffix(forPath: "/Users/omer/.claude"), "073dcc5f")
        let named = ClaudeAccount(slug: "work", directory: URL(fileURLWithPath: "/Users/omer/.claude-work"))
        XCTAssertEqual(named.keychainServices.count, 1)
    }
}
