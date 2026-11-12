import AppKit
import SwiftUI

/// `Waitlight --demo <file.png>`: the panel with sample sessions and readings,
/// drawn to a PNG for the README, so a screenshot shows nobody's real projects.
@MainActor
enum Demo {
    private static var window: NSWindow?

    static func render(to url: URL) {
        let board = SessionBoard(monitor: ClaudeSessionMonitor(discover: { [] }))
        let usage = ClaudeUsage()
        let now = Date()
        let personal = ClaudeAccount(slug: nil, directory: URL(fileURLWithPath: "/tmp/.claude"))
        let work = ClaudeAccount(slug: "work", directory: URL(fileURLWithPath: "/tmp/.claude-work"))

        func tracked(_ pid: Int32, _ name: String, _ state: AgentSession.State, minutesAgo: Double,
                     surface: String = "Terminal", waitingFor: String? = nil,
                     account: ClaudeAccount) -> ClaudeSessionMonitor.Tracked {
            let session = AgentSession(id: "claude.\(pid)", name: name, detail: "\(surface) · \(name)", state: state,
                                       waitingFor: waitingFor, since: now.addingTimeInterval(-minutesAgo * 60),
                                       processID: pid)
            return .init(session: session, account: account, cwd: "/tmp/\(name)")
        }
        // A turn only reads as done once it has been seen working.
        board.apply([tracked(2, "landing-page", .busy, minutesAgo: 9, surface: "VS Code", account: personal)])
        board.apply([
            tracked(1, "checkout-api", .waiting, minutesAgo: 14, waitingFor: "permission prompt", account: work),
            tracked(2, "landing-page", .idle, minutesAgo: 2, surface: "VS Code", account: personal),
            tracked(3, "mobile-app", .busy, minutesAgo: 6, account: personal),
            tracked(4, "docs", .idle, minutesAgo: 80, account: personal),
        ])
        usage.loadDemo([
            AccountUsage(account: personal, plan: "Pro", windows: [
                UsageWindow(label: L10n.t("Current session"), percent: 18, resetsAt: now.addingTimeInterval(2.8 * 3600)),
                UsageWindow(label: L10n.t("All models"), percent: 48, resetsAt: now.addingTimeInterval(31 * 3600)),
                UsageWindow(label: "Fable", percent: 41, resetsAt: now.addingTimeInterval(31 * 3600)),
            ], readAt: now),
            AccountUsage(account: work, plan: "Max", windows: [
                UsageWindow(label: L10n.t("Current session"), percent: 72, resetsAt: now.addingTimeInterval(1.2 * 3600)),
                UsageWindow(label: L10n.t("All models"), percent: 23, resetsAt: now.addingTimeInterval(4.5 * 24 * 3600)),
            ], readAt: now),
        ])

        let panel = PanelView(close: {})
            .environmentObject(board)
            .environmentObject(usage)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.13)))
            .padding(1)
        let hosting = NSHostingView(rootView: panel)
        hosting.setFrameSize(hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderFrontRegardless()
        Demo.window = window

        // After a moment, so the bars and checkboxes have been laid out and drawn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            NSApp.terminate(nil)
        }
    }
}
