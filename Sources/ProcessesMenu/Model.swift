import Foundation
import Darwin

// Shared contract between the data layer (ProcessService, Attribution) and the UI.
// Owned by the lead: change only in coordination.

struct ProcessEntry: Identifiable, Sendable {
    let pid: pid_t
    let name: String
    let owner: String
    let uid: uid_t
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
    var parentPID: pid_t = 0
    var processGroup: pid_t = 0
    var residentBytes: UInt64? = nil
    var command: String = ""
    var listeningPorts: [String] = []
    var workingDirectory: String = ""
    /// Agent identity read from a whitelist of environment keys (see Attribution). Never other env values.
    var agentMarker: AgentMarker? = nil
    var id: pid_t { pid }
    var canTerminate: Bool { pid > 1 && pid != getpid() && uid == getuid() }
    var memoryLabel: String {
        residentBytes.map { String(format: "%.0f МБ", Double($0) / 1_048_576) } ?? "— МБ"
    }
    var ageLabel: String { Self.durationLabel(seconds: max(0, Int(Date().timeIntervalSince1970) - Int(startedSeconds))) }

    static func durationLabel(seconds: Int) -> String {
        if seconds >= 86400 { return "\(seconds / 86400) д \(seconds % 86400 / 3600) ч" }
        if seconds >= 3600 { return "\(seconds / 3600) ч \(seconds % 3600 / 60) мин" }
        if seconds >= 60 { return "\(seconds / 60) мин" }
        return "\(seconds) с"
    }
}

enum AgentKind: String, Sendable, CaseIterable {
    case claude, codex, kimi, cursor
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .kimi: "Kimi"
        case .cursor: "Cursor"
        }
    }
}

/// Session identity inherited by every process an agent spawns, e.g. CLAUDE_CODE_SESSION_ID or CODEX_THREAD_ID.
struct AgentMarker: Hashable, Sendable {
    let kind: AgentKind
    let sessionID: String
    /// PID of the agent process that owns the session, when the environment names it
    /// (Claude: CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/<pid>.sock). Lets detached children (PPID 1) of a live agent
    /// stay attributed to a live session. Group sessions by (kind, sessionID), not by the whole marker.
    var hostPID: pid_t? = nil
}

enum ProcessRole: Sendable {
    case server     // has TCP LISTEN ports
    case browser    // Chrome/Chromium/headless shells, Playwright browsers, WebKit/Firefox test builds
    case mcp        // MCP servers (e.g. `npm exec @playwright/mcp`) — part of a live agent, low priority
    case agent      // the agent process itself (claude, codex, codex daemon, helpers like codex-code-mode-host)
    case helper     // npm/sh wrappers, node children of servers etc.
    case other
}

struct AttributedProcess: Identifiable, Sendable {
    let entry: ProcessEntry
    let role: ProcessRole
    /// Depth inside the session's tree (0 = top-level item shown to the user; wrappers like `npm run dev` collapse into it).
    let depth: Int
    /// The whole subtree this item stands for (itself + wrappers/children), used by "Stop" to stop everything together.
    let tree: [ProcessEntry]
    var id: pid_t { entry.pid }
}

enum SessionState: Sendable, Equatable {
    case active                 // agent process alive and (for daemon threads) recently active
    case idle(seconds: Int)     // agent host alive but this session quiet for a long time (e.g. Codex desktop thread)
    case ended                  // no agent process for this session any more
    case host                   // owned by a live agent host (Codex app daemon) itself, not by one of its threads
}

struct AgentSession: Identifiable, Sendable {
    let id: String                 // "<kind>:<sessionID>" or "<kind>:pid:<pid>"
    let kind: AgentKind
    let sessionID: String?
    let agentPID: pid_t?           // nil when the agent is gone
    let projectPath: String        // agent cwd, else the cwd of its first process
    let startedSeconds: UInt64
    let state: SessionState
    /// What the agent launched, excluding the agent's own processes. Sorted: servers, browsers, other, mcp.
    let processes: [AttributedProcess]
    var projectName: String {
        let name = (projectPath as NSString).lastPathComponent
        return name.isEmpty ? "—" : name
    }
}

struct AttributedSnapshot: Sendable {
    /// Sessions whose agent is still working (state == .active or .host).
    let liveSessions: [AgentSession]
    /// Sessions in .ended or .idle state (never .host) that still have processes: what was left behind. Shown first in the UI.
    let leftoverSessions: [AgentSession]
    /// Listening servers not attributed to any agent (the owner's own dev servers, system services).
    let otherServers: [AttributedProcess]
    /// Raw list for the "All processes" tab.
    let all: [ProcessEntry]
    /// Number of top-level leftover items (badge in the menu bar).
    var leftoverCount: Int { leftoverSessions.reduce(0) { $0 + $1.processes.count } }

    static let empty = AttributedSnapshot(liveSessions: [], leftoverSessions: [], otherServers: [], all: [])
}

struct StopResult: Sendable {
    let stopped: [pid_t]       // exited after SIGTERM
    let killed: [pid_t]        // needed SIGKILL
    let failed: [pid_t: String]
}
