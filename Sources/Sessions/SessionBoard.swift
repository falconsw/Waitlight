import AppKit
import Combine
import Foundation

/// What the menu bar and the panel draw: every session, in the words a person
/// cares about.
///
/// Claude Code reports `busy`, `waiting` and `idle`. The one thing it does not
/// say is that a turn *finished*: that is `busy` turning `idle`, which only
/// someone watching the change can see. So the board keeps that as `done` until
/// you go back to the session or it starts working again.
@MainActor
final class SessionBoard: ObservableObject {
    enum Phase: Int, Comparable {
        case waiting, done, working, idle
        static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }
    }

    struct Row: Identifiable, Equatable {
        let tracked: ClaudeSessionMonitor.Tracked
        let phase: Phase
        let since: Date
        var id: String { tracked.id }
        var session: AgentSession { tracked.session }
        var project: String { (tracked.cwd as NSString).lastPathComponent }
    }

    @Published private(set) var rows: [Row] = []

    /// When each session's turn ended, for the sessions not yet gone back to.
    private var finished: [String: Date] = [:]
    private var previous: [String: AgentSession.State] = [:]
    private var cancellables: Set<AnyCancellable> = []

    /// Told about a session that just started waiting or just finished.
    var onWaiting: (Row) -> Void = { _ in }
    var onDone: (Row) -> Void = { _ in }

    var waiting: [Row] { rows.filter { $0.phase == .waiting } }
    var working: [Row] { rows.filter { $0.phase == .working } }
    var done: [Row] { rows.filter { $0.phase == .done } }

    init(monitor: ClaudeSessionMonitor) {
        monitor.$sessions
            .dropFirst()   // the empty list it starts with is not a reading
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.apply($0) }
            .store(in: &cancellables)
    }

    func apply(_ sessions: [ClaudeSessionMonitor.Tracked]) {
        var started: [Row] = []
        var ended: [Row] = []
        for tracked in sessions {
            let id = tracked.id, state = tracked.session.state
            let before = previous[id]
            if state == .busy || state == .waiting { finished[id] = nil }
            if before == .busy, state == .idle { finished[id] = tracked.session.since }
            // Seen for the first time already idle, which is every session open when
            // the app starts: nobody watched its turn end, but the record says when
            // it did. A session that has not been used yet went idle as it opened.
            if before == nil, state == .idle, Self.endedATurn(tracked) { finished[id] = tracked.session.since }
            let row = Self.row(tracked, finished: finished[id])
            if before != nil, before != .waiting, state == .waiting { started.append(row) }
            if before == .busy, state == .idle { ended.append(row) }
        }
        let live = Set(sessions.map(\.id))
        finished = finished.filter { live.contains($0.key) }
        previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.session.state) })

        rows = sessions
            .map { Self.row($0, finished: finished[$0.id]) }
            .sorted { $0.phase == $1.phase ? $0.since < $1.since : $0.phase < $1.phase }
        started.forEach(onWaiting)
        ended.forEach(onDone)
    }

    /// Back to the session's tab; a finished turn counts as seen.
    func open(_ row: Row) {
        TabFocus.focus(pid: row.session.processID ?? 0, cwd: row.tracked.cwd)
        guard finished[row.id] != nil else { return }
        finished[row.id] = nil
        rows = rows.map { $0.id == row.id ? Self.row($0.tracked, finished: nil) : $0 }
            .sorted { $0.phase == $1.phase ? $0.since < $1.since : $0.phase < $1.phase }
    }

    /// How long ago a turn may have ended and still be shown as done when the
    /// app starts; older than this it is a session left open, not news.
    static let freshness: TimeInterval = 60 * 60

    static func endedATurn(_ tracked: ClaudeSessionMonitor.Tracked, now: Date = Date()) -> Bool {
        guard let started = tracked.startedAt else { return false }
        let since = tracked.session.since
        return since.timeIntervalSince(started) > 30 && now.timeIntervalSince(since) < freshness
    }

    func row(id: String) -> Row? { rows.first { $0.id == id } }

    private static func row(_ tracked: ClaudeSessionMonitor.Tracked, finished: Date?) -> Row {
        let session = tracked.session
        switch session.state {
        case .waiting: return Row(tracked: tracked, phase: .waiting, since: session.since)
        case .busy: return Row(tracked: tracked, phase: .working, since: session.since)
        case .idle, .success:
            if let finished { return Row(tracked: tracked, phase: .done, since: finished) }
            return Row(tracked: tracked, phase: .idle, since: session.since)
        }
    }
}
