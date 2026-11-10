import Foundation
import Darwin

@main
enum AttributionChecks {
    static let now = Date(timeIntervalSince1970: 10_000)
    static let claude = AgentMarker(kind: .claude, sessionID: "claude-synthetic")
    static let codex = AgentMarker(kind: .codex, sessionID: "codex-synthetic")

    static func entry(_ pid: pid_t, _ name: String, parent: pid_t = 1,
                      command: String = "", marker: AgentMarker? = nil,
                      ports: [String] = [], cwd: String = "/project") -> ProcessEntry {
        ProcessEntry(pid: pid, name: name, owner: "synthetic", uid: getuid(), startedSeconds: 1,
                     startedMicroseconds: 0, parentPID: parent, processGroup: 99,
                     command: command.isEmpty ? name : command, listeningPorts: ports,
                     workingDirectory: cwd, agentMarker: marker)
    }

    static func main() {
        let liveClaude = Attribution.build(from: [
            entry(100, "claude"),
            entry(101, "npm exec", parent: 100, command: "npm exec @playwright/mcp --browser chrome", marker: claude),
            entry(102, "node", parent: 101, command: "node /modules/@playwright/mcp/cli.js", marker: claude)
        ], now: now)
        precondition(liveClaude.liveSessions.count == 1 && liveClaude.leftoverSessions.isEmpty)
        let session = liveClaude.liveSessions[0]
        precondition(session.kind == .claude && session.state == .active && session.agentPID == 100)
        precondition(session.sessionID == claude.sessionID && session.processes.count == 1)
        precondition(session.processes[0].role == .mcp && session.processes[0].tree.count == 2)
        precondition(!session.processes[0].tree.contains { $0.pid == 100 })

        let orphan = Attribution.build(from: [
            entry(200, "npm run dev", marker: codex),
            entry(201, "sh", parent: 200, command: "sh -c vite", marker: codex),
            entry(202, "node", parent: 201, command: "node /project/node_modules/vite/bin/vite.js --port 8000", marker: codex, ports: ["8000"])
        ], now: now)
        precondition(orphan.liveSessions.isEmpty && orphan.leftoverSessions.count == 1)
        let leftover = orphan.leftoverSessions[0]
        precondition(leftover.state == .ended && leftover.agentPID == nil)
        precondition(leftover.processes.count == 1 && leftover.processes[0].entry.pid == 202)
        precondition(leftover.processes[0].role == .server && Set(leftover.processes[0].tree.map(\.pid)) == [200, 201, 202])

        let daemonTree = [
            entry(300, "codex", command: "/home/.codex/packages/app-server-daemon/bin/codex"),
            entry(301, "node", parent: 300, marker: codex, ports: ["8080"])
        ]
        let idle = Attribution.build(from: daemonTree, now: now,
                                     sessionFiles: [codex: .init(modifiedAt: now.addingTimeInterval(-1_200))])
        precondition(idle.liveSessions.isEmpty && idle.leftoverSessions[0].state == .idle(seconds: 1_200))
        let recent = Attribution.build(from: daemonTree, now: now,
                                       sessionFiles: [codex: .init(modifiedAt: now.addingTimeInterval(-30))])
        precondition(recent.liveSessions.count == 1 && recent.leftoverSessions.isEmpty)
        let boundary = Attribution.build(from: daemonTree, now: now,
                                         sessionFiles: [codex: .init(modifiedAt: now.addingTimeInterval(-600.5))])
        precondition(boundary.liveSessions.isEmpty && boundary.leftoverSessions[0].state == .idle(seconds: 600))
        let missingFile = Attribution.build(from: daemonTree, now: now)
        precondition(missingFile.liveSessions.isEmpty && missingFile.leftoverSessions.count == 1)
        let noAgent = Attribution.build(from: Array(daemonTree.dropFirst()), now: now,
                                        sessionFiles: [codex: .init(modifiedAt: now)])
        precondition(noAgent.liveSessions.isEmpty && noAgent.leftoverSessions[0].state == .ended)

        let manual = Attribution.build(from: [entry(400, "python", ports: ["9000"])], now: now)
        precondition(manual.liveSessions.isEmpty && manual.leftoverSessions.isEmpty)
        precondition(manual.otherServers.count == 1 && manual.otherServers[0].entry.pid == 400)

        var browsers = [entry(500, "Google Chrome for Testing", marker: claude)]
        browsers += (1...5).map { entry(pid_t(500 + $0), "Google Chrome Helper", parent: 500, marker: claude) }
        let browser = Attribution.build(from: browsers, now: now)
        precondition(browser.leftoverCount == 1)
        precondition(browser.leftoverSessions[0].processes[0].role == .browser)
        precondition(browser.leftoverSessions[0].processes[0].tree.count == 6)
        precondition(Attribution.role(entry(600, "headless_shell")) == .browser)
        precondition(Attribution.role(entry(603, "npm", command: "npm exec @playwright/mcp --browser firefox")) == .mcp)
        precondition(!Attribution.isCodexDaemon(entry(604, "codex", command: "codex exec inspect /app-server-daemon/log")))
        precondition(Attribution.role(entry(601, "firefox", command: "/cache/ms-playwright/firefox/firefox")) == .browser)
        precondition(Attribution.role(entry(602, "MiniBrowser", command: "/cache/ms-playwright/webkit/pw_run.sh")) == .browser)

        let cli = Attribution.build(from: [entry(700, "codex"), entry(701, "node", parent: 700, ports: ["3000"])], now: now)
        precondition(cli.liveSessions.count == 1 && cli.liveSessions[0].agentPID == 700)
        precondition(cli.liveSessions[0].sessionID == nil && cli.liveSessions[0].processes.count == 1)
        let helperOnly = Attribution.build(from: [entry(710, "codex-code-mode-host", marker: codex),
                                                 entry(711, "node", parent: 710, ports: ["3000"])], now: now)
        precondition(helperOnly.liveSessions.isEmpty && helperOnly.leftoverSessions.count == 1)
        precondition(helperOnly.leftoverSessions[0].processes.count == 1)

        let split = Attribution.build(from: [entry(800, "sh", marker: codex),
                                            entry(801, "vite", parent: 800, ports: ["8000"]),
                                            entry(802, "chromium", parent: 800)], now: now)
        precondition(split.leftoverCount == 2)
        precondition(split.leftoverSessions[0].processes.map(\.role) == [.server, .browser])
        precondition(Set(split.leftoverSessions[0].processes.flatMap(\.tree).map(\.pid)) == [800, 801, 802])

        // Markers override ancestry and cannot leak attribution across sessions or users.
        let second = AgentMarker(kind: .codex, sessionID: "second-synthetic")
        let separate = Attribution.build(from: [entry(900, "codex", marker: codex),
                                               entry(901, "node", parent: 900, marker: second, ports: ["1"])], now: now)
        precondition(separate.liveSessions.count == 2)
        var foreign = entry(902, "node", marker: codex, ports: ["2"])
        foreign = ProcessEntry(pid: foreign.pid, name: foreign.name, owner: "foreign", uid: getuid() + 1,
                               startedSeconds: 1, startedMicroseconds: 0, listeningPorts: foreign.listeningPorts,
                               agentMarker: codex)
        let foreignSnapshot = Attribution.build(from: [foreign], now: now)
        precondition(foreignSnapshot.leftoverSessions.isEmpty && foreignSnapshot.otherServers.count == 1)

        // A nested agent can inherit both kinds of marker. Its nearest agent wins.
        let inherited = [codex, claude]
        let nested = [entry(920, "claude"), entry(921, "node", parent: 920, marker: codex)]
        let resolvedClaude = ProcessService.resolvingMarkers(nested, candidates: [921: inherited])
        precondition(resolvedClaude[1].agentMarker == claude)
        let nestedCodex = [entry(922, "codex"), entry(923, "node", parent: 922, marker: claude)]
        let resolvedCodex = ProcessService.resolvingMarkers(nestedCodex, candidates: [923: inherited])
        precondition(resolvedCodex[1].agentMarker == codex)
        let plainTree = Attribution.build(from: [entry(930, "python", marker: claude),
                                                entry(931, "worker", parent: 930)], now: now)
        precondition(plainTree.leftoverCount == 1 && plainTree.leftoverSessions[0].processes[0].entry.pid == 930)

        let fallback = Attribution.build(from: [entry(950, "node", marker: claude, cwd: "")], now: now,
                                         sessionFiles: [claude: .init(modifiedAt: now, projectPath: "/fallback")])
        precondition(fallback.leftoverSessions[0].projectPath == "/fallback")
        let cyclic = Attribution.build(from: [entry(960, "sh", parent: 961, marker: codex),
                                             entry(961, "node", parent: 960, marker: codex)], now: now)
        precondition(cyclic.leftoverSessions[0].processes.flatMap(\.tree).count == 2)
        print("PASS: live Claude/MCP, orphan Codex/server wrappers, daemon mtime, manual server, browser helpers, CLI ancestry, session isolation, project fallback, cyclic parents")
    }
}
