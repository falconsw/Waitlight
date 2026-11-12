import CryptoKit
import Foundation

/// One Claude Code configuration directory, and so one account: `~/.claude`,
/// or a `~/.claude-<name>` that a `CLAUDE_CONFIG_DIR` alias keeps a second
/// login in (the convention Leftover reads too).
///
/// Each has its own token in the login keychain and its own `sessions` folder.
struct ClaudeAccount: Identifiable, Hashable {
    /// Nil for `~/.claude`; the part after `.claude-` otherwise.
    let slug: String?
    let directory: URL

    var id: String { slug ?? "default" }
    var sessionsDirectory: URL { directory.appendingPathComponent("sessions") }

    /// What the panel calls it when there is more than one.
    var name: String { slug ?? "Claude" }

    /// Every keychain service this account's token may be filed under.
    ///
    /// Claude Code files a token under the bare name plus the first eight hex
    /// digits of the SHA-256 of the directory's path, and does so for the
    /// default directory too whenever `CLAUDE_CONFIG_DIR` is set in the shell,
    /// so the default offers both and the newer token wins.
    var keychainServices: [String] {
        let suffixed = "Claude Code-credentials-\(Self.suffix(forPath: directory.path))"
        return slug == nil ? [suffixed, "Claude Code-credentials"] : [suffixed]
    }

    static func suffix(forPath path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    /// `~/.claude` and every `~/.claude-<name>` that Claude Code has used,
    /// alphabetically so accounts never swap places between launches.
    static func discover(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [ClaudeAccount] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let others = names
            .filter { $0.hasPrefix(".claude-") && $0.count > ".claude-".count }
            .sorted()
            .map { ClaudeAccount(slug: String($0.dropFirst(".claude-".count)), directory: home.appendingPathComponent($0)) }
            .filter(\.looksUsed)
        return [ClaudeAccount(slug: nil, directory: home.appendingPathComponent(".claude"))] + others
    }

    /// A directory Claude Code ran in leaves one of these behind; a folder that
    /// merely shares the prefix (a backup, a cache) leaves none.
    private var looksUsed: Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return false }
        return ["sessions", "projects", ".claude.json", "settings.json"].contains {
            manager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }
}
