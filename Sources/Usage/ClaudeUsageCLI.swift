import Foundation

/// Claude Code's own `/usage`, asked of the binary instead of the endpoint.
///
/// The endpoint refuses requests for long stretches (HTTP 429) once anything
/// on the Mac has asked it too often; `claude "/usage"` prints the same figures
/// and is not refused with it. Used only then, because it costs a process
/// launch where the endpoint costs a request. The approach is Leftover's.
enum ClaudeUsageCLI {
    /// No transcript and no MCP servers: `/usage` needs neither.
    static let arguments = ["--print", "--no-session-persistence", "--strict-mcp-config", "/usage"]

    /// One fixed working directory, so Claude Code files at most one project
    /// folder for these runs, and the session monitor can tell them from yours.
    static var scratchDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Waitlight/usage-scratch", isDirectory: true)
    }

    /// The app is opened from Finder, so the shell's PATH is not there to ask.
    static func binary(home: String = NSHomeDirectory()) -> URL? {
        ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
         "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func read(_ account: ClaudeAccount) async -> [UsageWindow] {
        await Task.detached { () -> [UsageWindow] in
            guard let binary = binary() else { return [] }
            try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            process.currentDirectoryURL = scratchDirectory
            var environment = ProcessInfo.processInfo.environment
            // An npm install of Claude Code starts through `node`, which Finder's PATH lacks.
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
            if account.slug != nil { environment["CLAUDE_CONFIG_DIR"] = account.directory.path }
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            // A CLI that hangs must not hold every later reading behind it.
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            return parse(String(decoding: data, as: UTF8.self))
        }.value
    }

    /// Lines such as `Current week (Fable): 48% used · resets Nov 14 at 7am (Europe/Istanbul)`.
    static func parse(_ text: String, now: Date = Date()) -> [UsageWindow] {
        let line = try! NSRegularExpression(
            pattern: #"^Current (session|week)(?: \(([^)]+)\))?: (\d+(?:\.\d+)?)% used(?: · resets (.+?)(?: \(([^)]+)\))?)?$"#)
        return text.split(separator: "\n").compactMap { raw -> UsageWindow? in
            let string = raw.trimmingCharacters(in: .whitespaces)
            guard let match = line.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else { return nil }
            func group(_ index: Int) -> String? {
                Range(match.range(at: index), in: string).map { String(string[$0]) }
            }
            guard let percent = group(3).flatMap(Double.init) else { return nil }
            let label: String
            switch (group(1), group(2)) {
            case ("session", _): label = L10n.t("Current session")
            case (_, "all models"), (_, nil): label = L10n.t("All models")
            case (_, let model?): label = model
            }
            let zone = group(5).flatMap(TimeZone.init(identifier:)) ?? .current
            return UsageWindow(label: label, percent: percent,
                               resetsAt: group(4).flatMap { resetDate($0, zone: zone, now: now) })
        }
    }

    /// `Nov 14 at 6:59am`, `Nov 14 at 7am`, or a bare `2:30am` for later today.
    /// No year is printed, so the next time that date comes round is meant.
    static func resetDate(_ text: String, zone: TimeZone, now: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.defaultDate = calendar.startOfDay(for: now)
        for (format, hasDay) in [("MMM d 'at' h:mma", true), ("MMM d 'at' ha", true), ("h:mma", false), ("ha", false)] {
            formatter.dateFormat = format
            guard var date = formatter.date(from: text) else { continue }
            if date < now.addingTimeInterval(-60) {
                date = calendar.date(byAdding: hasDay ? .year : .day, value: 1, to: date) ?? date
            }
            return date
        }
        return nil
    }
}
