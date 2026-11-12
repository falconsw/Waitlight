import AppKit

@main
enum WaitlightMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: ClaudeSessionMonitor?
    private var board: SessionBoard?
    private var usage: ClaudeUsage?
    private var notifier: Notifier?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Unit tests run inside the app; they need none of this.
            guard NSClassFromString("XCTestCase") == nil else { return }

            if let flag = CommandLine.arguments.firstIndex(of: "--demo") {
                let path = CommandLine.arguments.dropFirst(flag + 1).first ?? "docs/panel.png"
                Demo.render(to: URL(fileURLWithPath: path))
                return
            }

            let monitor = ClaudeSessionMonitor()
            let board = SessionBoard(monitor: monitor)
            let usage = ClaudeUsage()
            notifier = Notifier(board: board)
            menuBar = MenuBarController(board: board, usage: usage)

            // A turn's end is when the plan's use has moved.
            let onDone = board.onDone
            board.onDone = { row in
                onDone(row)
                usage.refreshIfStale()
            }

            monitor.start()
            usage.start()
            self.monitor = monitor
            self.board = board
            self.usage = usage
        }
    }
}
