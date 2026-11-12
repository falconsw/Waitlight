import AppKit
import Foundation

/// Takes you to the window, and where the host allows it the tab, a session
/// runs in.
///
/// * **Terminal.app** and **iTerm2**: the tab whose tty is the session's, over
///   AppleScript (a one-time Automation consent per terminal).
/// * **VS Code** and its forks: `open -b <editor> <folder>` raises the window
///   that has the session's folder open.
/// * Everything else (Ghostty, Warp, the Claude app…): the app is raised.
enum TabFocus {
    static func focus(pid: pid_t, cwd: String?) {
        guard let app = regularApp(of: pid) else { return }
        let bundle = app.bundleIdentifier ?? ""
        let tty = SessionFocus.tty(of: pid).map { "/dev/" + $0 }

        switch bundle {
        case "com.apple.Terminal" where tty != nil:
            run(script: """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty!)" then
                            set selected of t to true
                            set index of w to 1
                        end if
                    end repeat
                end repeat
                activate
            end tell
            """, fallback: app)
        case "com.googlecode.iterm2" where tty != nil:
            run(script: """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty!)" then
                                select w
                                tell t to select
                                tell s to select
                            end if
                        end repeat
                    end repeat
                end repeat
                activate
            end tell
            """, fallback: app)
        case _ where editors.contains(bundle) && cwd != nil:
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-b", bundle, cwd!]
            if (try? open.run()) == nil { app.activate() }
        default:
            app.activate()
        }
    }

    /// Editors that open a folder in the window that already has it.
    private static let editors: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf",
        "com.vscodium",
    ]

    /// The nearest ancestor that is an app with a Dock icon. `owningApp` alone
    /// can stop at a helper (VS Code's extension host is an app of its own),
    /// and raising a helper raises nothing.
    static func regularApp(of pid: pid_t) -> NSRunningApplication? {
        for candidate in SessionFocus.ancestry(of: pid, limit: 12) {
            if let app = NSRunningApplication(processIdentifier: candidate),
               app.activationPolicy == .regular {
                return app
            }
        }
        return SessionFocus.owningApp(of: pid)
    }

    /// Whether the app a session runs in is the one in front, which is when a
    /// notification about it would only repeat what is on screen.
    static func isInFront(pid: pid_t) -> Bool {
        guard let app = regularApp(of: pid) else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private static func run(script: String, fallback: NSRunningApplication) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    // Automation refused or the tab is gone: the app is still worth raising.
                    DispatchQueue.main.async { fallback.activate() }
                }
            } catch {
                DispatchQueue.main.async { fallback.activate() }
            }
        }
    }
}
