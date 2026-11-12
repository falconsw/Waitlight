import ServiceManagement
import SwiftUI

/// The panel: sessions first (what needs you at the top), then what is left of
/// each Claude account's plan, then the few switches there are.
struct PanelView: View {
    let close: () -> Void
    @EnvironmentObject private var board: SessionBoard
    @EnvironmentObject private var usage: ClaudeUsage

    var body: some View {
        // Re-evaluated every few seconds so the "4 min" figures move while it is open.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(alignment: .leading, spacing: 14) {
                sessions(now: context.date)
                Divider()
                plans(now: context.date)
                Divider()
                FooterView()
            }
            .padding(14)
            .frame(width: 340)
        }
    }

    // MARK: - Sessions

    @ViewBuilder
    private func sessions(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sessions").font(.headline)
            if board.rows.isEmpty {
                Text("No Claude Code session is open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(board.rows) { row in
                    SessionRowView(row: row, now: now,
                                   showsAccount: usage.signedIn.count > 1) {
                        board.open(row)
                        close()
                    }
                }
            }
        }
    }

    // MARK: - Plans

    @ViewBuilder
    private func plans(now: Date) -> some View {
        let accounts = usage.signedIn
        VStack(alignment: .leading, spacing: 10) {
            if accounts.isEmpty {
                Text("Claude usage").font(.headline)
                Text("Sign in to Claude Code to see what is left of your plan.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(accounts) { account in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(account.account.name).font(.headline)
                        if let plan = account.plan {
                            Text(plan).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let problem = account.problem {
                            Text(Self.describe(problem))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if account.windows.isEmpty, account.problem == nil {
                        Text("Reading…").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(account.windows, id: \.label) { window in
                        UsageBar(window: window, now: now)
                    }
                    if account.problem != nil, let readAt = account.readAt {
                        Text(L10n.t("Last read \(L10n.duration(now.timeIntervalSince(readAt))) ago"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    static func describe(_ problem: AccountUsage.Problem) -> String {
        switch problem {
        case .signedOut: return L10n.t("Not signed in")
        case .expired: return L10n.t("Updates when Claude Code next runs")
        case .unreachable: return L10n.t("Could not read just now")
        case .rateLimited: return L10n.t("Claude is limiting requests · retrying later")
        }
    }
}

private struct SessionRowView: View {
    let row: SessionBoard.Row
    let now: Date
    let showsAccount: Bool
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(row.project).font(.body.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Text(L10n.duration(now.timeIntervalSince(row.since)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(row.phase == .waiting ? Color.red : .secondary)
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(isHovered ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(Text("Go to this session"))
    }

    private var color: Color {
        switch row.phase {
        case .waiting: return .red
        case .done: return .green
        case .working: return .orange
        case .idle: return .secondary.opacity(0.5)
        }
    }

    private var detail: String {
        var parts: [String] = []
        switch row.phase {
        case .waiting:
            parts.append(row.session.waitingFor.map { L10n.t("Waiting for you: \($0)") } ?? L10n.t("Waiting for you"))
        case .done: parts.append(L10n.t("Done · your turn"))
        case .working: parts.append(L10n.t("Working"))
        case .idle: parts.append(L10n.t("Idle"))
        }
        parts.append(row.session.detail.components(separatedBy: " · ").first ?? "")
        if showsAccount { parts.append(row.tracked.account.name) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct UsageBar: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label).font(.callout)
                Spacer()
                Text("\(Int(window.percent.rounded()))%")
                    .font(.callout.monospacedDigit().weight(.medium))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(tint)
                        .frame(width: geometry.size.width * min(max(window.percent / 100, 0), 1))
                }
            }
            .frame(height: 6)
            if let reset = window.resetsAt, reset > now {
                Text(L10n.reset(at: reset, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tint: Color {
        switch window.percent {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }
}

private struct FooterView: View {
    @AppStorage(Notifier.waitingKey) private var notifyWaiting = true
    @AppStorage(Notifier.doneKey) private var notifyDone = true
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Notify when a session waits for me", isOn: $notifyWaiting)
            Toggle("Notify when a turn ends", isOn: $notifyDone)
            Toggle("Open at login", isOn: $opensAtLogin)
                .onChange(of: opensAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        opensAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            HStack {
                Spacer()
                Button("Quit Waitlight") { NSApp.terminate(nil) }
            }
        }
        .toggleStyle(.checkbox)
        .font(.callout)
    }
}
