#if PROCESS_UI_CHECKS
import Foundation
import Darwin

/// Synthetic identities only: never send these fixtures to ProcessService.stop.
enum UIFixtures {
    static func entry(_ pid: pid_t, _ name: String, minutes: Int = 12, memory: UInt64 = 8, ports: [String] = [], cwd: String = "", parent: pid_t = 0) -> ProcessEntry {
        ProcessEntry(pid: pid, name: name, owner: "fixture", uid: getuid(),
                     startedSeconds: UInt64(Date().timeIntervalSince1970) - UInt64(minutes * 60), startedMicroseconds: 0,
                     parentPID: parent, residentBytes: memory * 1_048_576,
                     command: "/fixture/bin/\(name) --project \(cwd)", listeningPorts: ports, workingDirectory: cwd)
    }

    static func item(_ entry: ProcessEntry, role: ProcessRole, children: [ProcessEntry] = []) -> AttributedProcess {
        AttributedProcess(entry: entry, role: role, depth: 0, tree: [entry] + children)
    }

    static func session(_ id: String, _ kind: AgentKind, _ project: String, minutes: Int, state: SessionState = .active, items: [AttributedProcess]) -> AgentSession {
        AgentSession(id: id, kind: kind, sessionID: id, agentPID: state == .ended ? nil : 88_000,
                     projectPath: project.isEmpty ? "" : "/fixture/projects/" + project,
                     startedSeconds: UInt64(Date().timeIntervalSince1970) - UInt64(minutes * 60),
                     state: state, processes: items)
    }

    static var agents: AttributedSnapshot {
        let vite = item(entry(91_001, "vite", minutes: 7, memory: 64, ports: ["8000"], cwd: "/fixture/projects/sessions-online-third/frontend"), role: .server,
                        children: [entry(91_002, "node worker", minutes: 7, memory: 12, parent: 91_001)])
        let chrome = item(entry(91_003, "Chrome headless", minutes: 120, memory: 128), role: .browser)
        let codexMCP = item(entry(91_004, "playwright-mcp", memory: 92), role: .mcp)
        let claudeMCP = item(entry(91_005, "playwright-mcp (headless)", minutes: 205, memory: 8), role: .mcp)
        let leftoverMCP = item(entry(91_015, "filesystem-mcp", minutes: 80, memory: 13), role: .mcp)
        let liveVite = item(entry(91_010, "vite development server for an exceptionally long frontend project name", memory: 72, ports: ["3003"], cwd: "/fixture/projects/vglub-landing-fourth"), role: .server)
        let liveMCPs = ["playwright-mcp", "figma-mcp", "filesystem-mcp"].enumerated().map {
            item(entry(pid_t(91_011 + $0.offset), $0.element, memory: 13), role: .mcp)
        }
        let liveBrowser = item(entry(91_014, "Chrome headless", memory: 32), role: .browser)
        let leftovers = [
            session("ended-codex", .codex, "sessions-online-third/frontend", minutes: 7, state: .ended, items: [vite]),
            session("ended-claude", .claude, "", minutes: 120, state: .ended, items: [chrome, leftoverMCP])
        ]
        let live = [
            session("live-codex", .codex, "sessions-online-third", minutes: 12, items: [codexMCP]),
            session("live-claude", .claude, "vglub-landing", minutes: 205, items: [claudeMCP]),
            session("live-empty", .claude, "processes-app", minutes: 2, items: []),
            session("live-vite", .codex, "vglub-landing-fourth", minutes: 8, items: [liveVite] + liveMCPs),
            session("live-browser", .cursor, "browser-validation", minutes: 16, items: [liveBrowser]),
            session("live-second-empty", .kimi, "a-long-project-name-for-empty-session-truncation", minutes: 34, items: [])
        ]
        let others = [
            item(entry(91_006, "OrbStack", minutes: 300, memory: 180, ports: ["8080"]), role: .server),
            item(entry(91_007, "ControlCenter", minutes: 300, memory: 24, ports: ["5000"]), role: .server)
        ]
        let long = entry(91_008, "node very-long-development-server-name-with-many-project-identifiers", memory: 16,
                         ports: ["3000", "3001"], cwd: "/fixture/projects/a-very-long-project-name-for-truncation-checks/frontend")
        return AttributedSnapshot(liveSessions: live, leftoverSessions: leftovers, otherServers: others,
                                  all: (leftovers + live).flatMap { $0.processes.flatMap(\.tree) } + others.map(\.entry) + [long])
    }

    static var liveOnly: AttributedSnapshot {
        let fixture = agents
        return AttributedSnapshot(liveSessions: fixture.liveSessions, leftoverSessions: [], otherServers: [],
                                  all: fixture.liveSessions.flatMap { $0.processes.map(\.entry) })
    }

    static var longNames: AttributedSnapshot {
        let process = item(entry(91_009, "very-long-development-server-name-with-many-project-identifiers", memory: 143, ports: ["12345", "54321"]), role: .server)
        return AttributedSnapshot(liveSessions: [],
            leftoverSessions: [session("long", .cursor, "a-very-long-project-name-for-truncation-checks/frontend", minutes: 93, state: .idle(seconds: 780), items: [process])],
            otherServers: [], all: [process.entry])
    }
}
#endif
