import AppKit
import Combine
import SwiftUI

/// The menu bar item: what needs you, at a glance, then the plan's 5-hour use.
///
/// `● 2 · 4 min  11%`: red while a session waits (how many, and the longest
/// wait), green while a finished turn is unseen, amber while sessions work.
@MainActor
final class MenuBarController {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let board: SessionBoard
    private let usage: ClaudeUsage
    private var cancellables: Set<AnyCancellable> = []
    private var clock: Timer?

    init(board: SessionBoard, usage: ClaudeUsage) {
        self.board = board
        self.usage = usage
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover.behavior = .transient
        popover.animates = true
        let panel = PanelView(close: { [weak popover] in popover?.performClose(nil) })
            .environmentObject(board)
            .environmentObject(usage)
        let hosting = NSHostingController(rootView: panel)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        if let button = item.button {
            let image = NSImage(systemSymbolName: "light.beacon.max", accessibilityDescription: "Waitlight")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.action = #selector(toggle)
            button.target = self
        }

        updateTitle()
        board.objectWillChange.merge(with: usage.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                // objectWillChange fires before the value lands; read it on the next turn.
                DispatchQueue.main.async { self?.updateTitle() }
            }
            .store(in: &cancellables)

        // The wait's minutes keep counting with nothing changing on disk.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTitle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func updateTitle() {
        let title = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        func add(_ text: String, _ color: NSColor? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if let color { attributes[.foregroundColor] = color }
            title.append(NSAttributedString(string: text, attributes: attributes))
        }

        let waiting = board.waiting, done = board.done, working = board.working
        if let longest = waiting.map(\.since).min() {
            add(" ●", .systemRed)
            add(waiting.count > 1 ? " \(waiting.count) · " : " ")
            add(L10n.duration(Date().timeIntervalSince(longest)))
        } else if !done.isEmpty {
            add(" ●", .systemGreen)
            if done.count > 1 { add(" \(done.count)") }
        } else if !working.isEmpty {
            add(" ●", .systemOrange)
            if working.count > 1 { add(" \(working.count)") }
        }

        // The most used account's 5-hour window: the one that runs out first.
        if let used = usage.accounts.compactMap(\.session?.percent).max() {
            add("  \(Int(used.rounded()))%")
        }
        item.button?.attributedTitle = title
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        usage.refreshIfStale()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
