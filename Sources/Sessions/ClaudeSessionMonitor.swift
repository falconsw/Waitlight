import Combine
import Foundation

/// Watches every account's `sessions` folder (`~/.claude/sessions`, and each
/// `~/.claude-<name>/sessions`) and publishes the Claude Code sessions that are
/// actually running, with what each is doing.
///
/// Claude Code writes `status` (`busy`, `waiting`, `idle`) into each session's
/// record from its own interface, so nothing has to be hooked into it. The
/// directory is watched for the moment a state changes; the timer covers a
/// process that died without touching its file.
///
/// Trimmed from Leftover's monitor: no transcript reading, so sessions that
/// publish no status (the ones the Claude desktop app hosts) are left out rather
/// than guessed at.
@MainActor
final class ClaudeSessionMonitor: ObservableObject {
    /// A session and the account whose folder it was found in.
    struct Tracked: Equatable, Identifiable {
        let session: AgentSession
        let account: ClaudeAccount
        let cwd: String
        /// When the session opened, so an idle one seen for the first time can be
        /// told from one that has not been used yet.
        var startedAt: Date? = nil
        var id: String { session.id }
    }

    @Published private(set) var sessions: [Tracked] = []

    private var accounts: [ClaudeAccount] = []
    private let discover: () -> [ClaudeAccount]
    private let livenessInterval: TimeInterval
    private var sources: [DispatchSourceFileSystemObject] = []
    private var livenessTimer: Timer?
    private var debounce: DispatchWorkItem?

    init(discover: @escaping () -> [ClaudeAccount] = { ClaudeAccount.discover() },
         livenessInterval: TimeInterval = 2) {
        self.discover = discover
        self.livenessInterval = livenessInterval
    }

    func start() {
        stop()
        accounts = discover()
        rescan()
        accounts.forEach { watch($0.sessionsDirectory) }

        let timer = Timer(timeInterval: livenessInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        livenessTimer = timer
    }

    func stop() {
        livenessTimer?.invalidate()
        livenessTimer = nil
        debounce?.cancel()
        sources.forEach { $0.cancel() }
        sources = []
    }

    private func watch(_ directory: URL) {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }   // no directory yet; the timer still covers us

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRescan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources.append(source)
    }

    /// A single state change can produce several file events; coalesce them.
    private func scheduleRescan() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func rescan() {
        var found: [Tracked] = []
        for account in accounts {
            for record in Self.read(directory: account.sessionsDirectory) {
                found.append(Tracked(session: record.session, account: account, cwd: record.cwd,
                                     startedAt: record.startedAt))
            }
        }
        found.sort { Self.newerFirst($0, $1) }
        guard found != sessions else { return }   // don't churn SwiftUI for nothing
        sessions = found
    }

    /// The live sessions in one `sessions` folder.
    nonisolated static func read(directory: URL,
                                 isAttended: (Int32) -> Bool = isAttended(pid:)) -> [ClaudeSessionRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let scratch = ClaudeUsageCLI.scratchDirectory.path
        let records = names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> ClaudeSessionRecord? in
                let url = directory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let record = ClaudeSessionRecord(json: json),
                      record.reportsStatus,
                      // The app's own `/usage` runs are sessions too, for the seconds they live.
                      record.cwd != scratch,
                      ProcessLiveness.isAlive(pid: record.pid, startedAt: record.startedAt),
                      !ProcessLiveness.isStopped(pid: record.pid),
                      !record.isFromSDK || isAttended(record.pid)
                else { return nil }
                return record
            }
        return deduplicated(records)
    }

    /// The id breaks ties so the order cannot flicker between two scans that read the same thing.
    nonisolated static func newerFirst(_ a: Tracked, _ b: Tracked) -> Bool {
        let x = a.session.since, y = b.session.since
        return x == y ? a.id < b.id : x > y
    }

    /// Whether somebody can be at this session: it has a terminal, or an
    /// application somewhere above it. Asked only of sessions a program started
    /// (`claude -p`, the Agent SDK), which are often nobody's.
    nonisolated static func isAttended(pid: Int32) -> Bool {
        SessionFocus.tty(of: pid) != nil || SessionFocus.owningApp(of: pid) != nil
    }

    /// Resuming after a crash registers a new pid while the old process is
    /// still winding down; Claude Code keeps the most recently started record,
    /// so this does the same rather than drawing one session twice.
    nonisolated static func deduplicated(_ records: [ClaudeSessionRecord]) -> [ClaudeSessionRecord] {
        var newest: [String: ClaudeSessionRecord] = [:]
        var loose: [ClaudeSessionRecord] = []
        for record in records {
            guard let id = record.sessionID else { loose.append(record); continue }
            if let held = newest[id], (held.startedAt ?? .distantPast) >= (record.startedAt ?? .distantPast) {
                continue
            }
            newest[id] = record
        }
        return Array(newest.values) + loose
    }
}
