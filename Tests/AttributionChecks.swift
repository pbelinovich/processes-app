import Foundation
import Darwin

@main
enum AttributionChecks {
    static let now = Date(timeIntervalSince1970: 10_000)
    static let claude = AgentMarker(kind: .claude, sessionID: "claude-synthetic")
    static let codex = AgentMarker(kind: .codex, sessionID: "codex-synthetic")

    static func entry(_ pid: pid_t, _ name: String, parent: pid_t = 1,
                      command: String = "", marker: AgentMarker? = nil,
                      ports: [String] = [], cwd: String = "/project", started: UInt64 = 1,
                      microseconds: UInt64 = 0) -> ProcessEntry {
        ProcessEntry(pid: pid, name: name, owner: "synthetic", uid: getuid(), startedSeconds: started,
                     startedMicroseconds: microseconds, parentPID: parent, processGroup: 99,
                     command: command.isEmpty ? name : command, listeningPorts: ports,
                     workingDirectory: cwd, agentMarker: marker)
    }

    static func main() {
        checkDisplayNames()
        checkNoiseAndApplicationExclusion()
        checkDetachedHosts()
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
        precondition(Attribution.role(entry(605, "node", command: "\"npm exec @playwright/mcp --browser chrome\"")) == .mcp)
        precondition(Attribution.role(entry(606, "zsh", command: "zsh -c \"echo inspecting @playwright/mcp\"")) == .helper)
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

        let directories: Set<String> = ["/Users", "/Users/synthetic", "/Users/synthetic/my-project"]
        precondition(Attribution.claudeProjectPath("-Users-synthetic-my-project", directoryExists: directories.contains) == "/Users/synthetic/my-project")
        precondition(Attribution.claudeProjectPath("-gone-project-name", knownPaths: ["/gone/project-name"], directoryExists: { _ in false }) == "/gone/project-name")
        precondition(Attribution.claudeProjectPath("-gone-project", directoryExists: { _ in false }) == "/gone/project")

        let fallback = Attribution.build(from: [entry(950, "node", marker: claude, cwd: "")], now: now,
                                         sessionFiles: [claude: .init(modifiedAt: now, projectPath: "/fallback")])
        precondition(fallback.leftoverSessions[0].projectPath == "/fallback")
        let cyclic = Attribution.build(from: [entry(960, "sh", parent: 961, marker: codex),
                                             entry(961, "node", parent: 960, marker: codex)], now: now)
        precondition(cyclic.leftoverSessions[0].processes.flatMap(\.tree).count == 2)
        print("PASS: live Claude/MCP, orphan Codex/server wrappers, daemon mtime, manual server, browser helpers, CLI ancestry, session isolation, project fallback, cyclic parents")
    }
    static func checkDisplayNames() {
        let cases: [(String, String, String)] = [
            ("node", "node --env-file=.env ./node_modules/.bin/vite --host 127.0.0.1 --port 8000", "vite"),
            ("npm exec", "npm exec @playwright/mcp@0.0.83 --headless", "playwright-mcp"),
            ("node", "node /cache/node_modules/.bin/playwright-mcp", "playwright-mcp"),
            ("node", "node /cache/node_modules/@playwright/mcp/cli.js --browser chrome", "playwright-mcp"),
            ("node", "node /cache/node_modules/vite/bin/vite.js --port 8000", "vite"),
            ("node", "node /cache/node_modules/next/dist/bin/next dev --port 3000", "next dev"),
            ("node", "node /cache/node_modules/tsx/dist/cli.mjs watch ./server.ts", "tsx watch"),
            ("python3", "python3 -m http.server 8080", "http.server"),
            ("Python", "/opt/Python -I /project/_supervise.py --secret never-show-this", "_supervise.py"),
            ("Python", "/opt/Python.app/Contents/MacOS/Python -I /project/_supervise.py", "_supervise.py"),
            ("python3.14", "python3.14 -u -m uvicorn app:main --host 127.0.0.1", "uvicorn"),
            ("python3", "python3 -m pytest /project/tests --verbose", "pytest"),
            ("python3", "python3 -X dev /project/worker.py --password never-show-this", "worker.py"),
            ("ruby", "ruby -r json /project/worker.rb --password never-show-this", "worker.rb"),
            ("java", "java -Xmx512m -jar /project/service.jar --token never-show-this", "service"),
            ("java", "java -cp /project/classes com.example.Server --port 9000", "com.example.Server"),
            ("bun", "bun run /project/server.ts --port 8000", "server.ts"),
            ("deno", "deno run --allow-net /project/server.ts --port 8000", "server.ts"),
            ("npx", "npx -y @playwright/mcp@0.0.83 --headless", "playwright-mcp"),
            ("pnpm", "pnpm exec next dev --port 3000", "next dev"),
            ("pnpm", "pnpm dlx @playwright/mcp --headless", "playwright-mcp"),
            ("yarn", "yarn exec tsx watch ./server.ts", "tsx watch"),
            ("npm", "npm exec --package=@playwright/mcp -- playwright-mcp --headless", "playwright-mcp"),
            ("npx", "npx --cache /cache -p @playwright/mcp playwright-mcp", "playwright-mcp"),
            ("npm run dev", "npm run dev -- --port 3000", "npm run dev"),
            ("node", "node --env-file .env --require /project/setup.js ./server.js --port 8080", "server"),
            ("node", "node --loader=tsx /project/server.ts --auth never-show-this", "server.ts"),
            ("node", "node --eval \"never-show-this\"", "node"),
            ("python3", "python3 -c \"never-show-this\"", "python3"),
            ("node", "node --unknown-option never-show-this /project/server.js", "node"),
            ("npm", "npm exec --unknown-option never-show-this vite", "npm"),
            ("node", "node \"/project with spaces/server.js\" --port 8000", "server"),
            ("Google Chrome Helper", "\"/Applications/Google Chrome for Testing.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper\" --type=renderer", "Google Chrome for Testing"),
            ("Firefox", "/Applications/Firefox.app/Contents/MacOS/firefox --headless", "Firefox"),
            ("vite", "/project/node_modules/.bin/vite preview --port 8000", "vite preview"),
            ("pytest", "/project/.venv/bin/pytest --verbose /project/tests", "pytest"),
            ("sleep", "/bin/sleep 60", "sleep"),
            ("node", "\"npm exec @playwright/mcp --headless\"", "playwright-mcp"),
            ("node", "\"npm exec @playwright/mcp@0.0.83\" \"\" \"\"", "playwright-mcp"),
            ("node", "\"node /cache/node_modules/.bin/vite --host 127.0.0.1\"", "vite"),
            ("fallback", "", "fallback")
        ]
        for (index, item) in cases.enumerated() {
            var process = entry(10_000, item.0, command: item.1)
            process.command = item.1
            let result = process.displayName
            precondition(result == item.2, "displayName case \(index): expected \(item.2), got \(result)")
            precondition(result.count <= 32 && !result.contains("/") && !result.contains("never-show-this"))
        }
        let long = String(repeating: "Ж", count: 40)
        precondition(entry(10_001, long, command: "").displayName.count == 32)
        print("PASS: displayName table (\(cases.count) command forms), 32-character limit, no paths/option values")
    }

    static func checkNoiseAndApplicationExclusion() {
        let tree = [
            entry(1_000, "claude", marker: claude),
            entry(1_001, "sed", parent: 1_000, marker: claude, started: 9_995),
            entry(1_002, "cut", parent: 1_000, marker: claude, started: 9_980, microseconds: 1),
            entry(1_003, "sleep", parent: 1_000, marker: claude, started: 9_980),
            entry(1_004, "sh", parent: 1_000, marker: claude, started: 9_999),
            entry(1_005, "chromium", parent: 1_000, marker: claude, started: 9_999),
            entry(1_006, "node", parent: 1_000, command: "node /cache/node_modules/@playwright/mcp/cli.js", marker: claude, started: 9_999),
            entry(1_007, "server", parent: 1_000, marker: claude, ports: ["8000"], started: 9_999),
            entry(1_008, "sh", parent: 1_000, marker: claude, started: 9_999),
            entry(1_009, "vite", parent: 1_008, marker: claude, ports: ["8001"], started: 9_999)
        ]
        let active = Attribution.build(from: tree, now: now)
        let visible = Set(active.liveSessions[0].processes.map(\.id))
        precondition(visible == [1_003, 1_005, 1_006, 1_007, 1_009])
        precondition(active.liveSessions[0].processes.first { $0.id == 1_009 }!.tree.contains { $0.pid == 1_008 })
        let ended = Attribution.build(from: Array(tree.dropFirst()), now: now)
        precondition(ended.leftoverSessions[0].processes.contains { $0.id == 1_001 })
        precondition(ended.leftoverSessions[0].processes.contains { $0.id == 1_002 })
        precondition(ended.leftoverSessions[0].processes.contains { $0.id == 1_004 })
        var idleTree = tree.map { entry -> ProcessEntry in var changed = entry; changed.agentMarker = codex; return changed }
        idleTree[0] = entry(1_000, "codex", command: "/home/app-server-daemon/bin/codex", marker: codex)
        let idle = Attribution.build(from: idleTree, now: now, sessionFiles: [codex: .init(modifiedAt: now.addingTimeInterval(-1_200))])
        precondition(idle.leftoverSessions[0].state == .idle(seconds: 1_200))
        precondition(idle.leftoverSessions[0].processes.contains { $0.id == 1_001 })

        let appCopies = [entry(getpid(), "checks", marker: claude),
                         entry(1_100, "ProcessesMenu", command: "/Applications/ProcessesMenu.app/Contents/MacOS/ProcessesMenu", marker: claude, ports: ["8000"]),
                         entry(1_101, "renamed", command: "\"/project with spaces/ProcessesMenu\"", marker: claude)]
        let excluded = Attribution.build(from: appCopies, now: now)
        precondition(excluded.liveSessions.isEmpty && excluded.leftoverSessions.isEmpty && excluded.otherServers.isEmpty)
        precondition(excluded.all.count == appCopies.count)
        let root = Attribution.build(from: [entry(1_200, "server", marker: claude, cwd: "/")], now: now)
        precondition(root.leftoverSessions[0].projectPath.isEmpty && root.leftoverSessions[0].projectName == "—")
        print("PASS: 20-second active noise boundary, server/browser/MCP exemptions, wrapper stop tree, ended/idle preservation, own/app-copy exclusion, root project normalization")
    }

    static func checkDetachedHosts() {
        let marker = AgentMarker(kind: .claude, sessionID: "detached-synthetic", hostPID: 2_000)
        let plain = AgentMarker(kind: .claude, sessionID: marker.sessionID)
        let host = entry(2_000, "claude", cwd: "/host-project")
        let detached = entry(2_001, "node", command: "node /cache/node_modules/@playwright/mcp/cli.js", marker: marker)
        let unlinked = entry(2_002, "Python", command: "python3 /project/_supervise.py", marker: plain)
        let snapshot = Attribution.build(from: [host, detached, unlinked], now: now)
        precondition(snapshot.leftoverSessions.isEmpty && snapshot.liveSessions.count == 1)
        let session = snapshot.liveSessions[0]
        precondition(session.agentPID == host.pid && session.state == .active && session.projectPath == "/host-project")
        precondition(session.sessionID == marker.sessionID && session.processes.count == 2)
        precondition(Set(session.processes.flatMap(\.tree).map(\.pid)) == [2_001, 2_002])
        // PID ordering/input ordering and host metadata must not produce extra pid-only sessions.
        let reversed = Attribution.build(from: [unlinked, detached, host], now: now)
        precondition(reversed.liveSessions.count == 1 && reversed.leftoverSessions.isEmpty)
        precondition(reversed.liveSessions[0].agentPID == host.pid)

        let absent = Attribution.build(from: [detached, unlinked], now: now)
        precondition(absent.liveSessions.isEmpty && absent.leftoverSessions.count == 1)
        precondition(absent.leftoverSessions[0].state == .ended && absent.leftoverSessions[0].agentPID == nil)
        let reused = Attribution.build(from: [entry(2_000, "sleep"), detached], now: now)
        precondition(reused.liveSessions.isEmpty && reused.leftoverSessions[0].state == .ended)
        let wrongKind = Attribution.build(from: [entry(2_000, "codex"), detached], now: now)
        precondition(wrongKind.leftoverSessions.count == 1 && wrongKind.leftoverSessions[0].state == .ended)
        let newerHost = Attribution.build(from: [entry(2_000, "claude", started: 2), detached], now: now)
        precondition(newerHost.leftoverSessions.count == 1 && newerHost.leftoverSessions[0].state == .ended)
        let newerMicroseconds = Attribution.build(from: [entry(2_000, "claude", microseconds: 1), detached], now: now)
        precondition(newerMicroseconds.leftoverSessions[0].state == .ended)
        let foreignHost = ProcessEntry(pid: 2_000, name: "claude", owner: "foreign", uid: getuid() + 1,
                                       startedSeconds: 1, startedMicroseconds: 0)
        let foreign = Attribution.build(from: [foreignHost, detached], now: now)
        precondition(foreign.liveSessions.isEmpty && foreign.leftoverSessions[0].state == .ended)

        // The host mechanism is generic: future marker providers can attach a Kimi/Cursor host.
        for (offset, kind) in [AgentKind.kimi, .cursor, .codex].enumerated() {
            let pid = pid_t(2_100 + offset)
            let future = AgentMarker(kind: kind, sessionID: "future-synthetic", hostPID: pid)
            let futureSnapshot = Attribution.build(from: [entry(pid, kind.rawValue), entry(pid + 10, "sleep", marker: future)], now: now)
            precondition(futureSnapshot.leftoverSessions.isEmpty && futureSnapshot.liveSessions.count == 1)
            precondition(futureSnapshot.liveSessions[0].agentPID == pid)
        }

        let daemon = entry(2_200, "codex", command: "/home/app-server-daemon/bin/codex")
        let threadHost = AgentMarker(kind: .codex, sessionID: "daemon-detached", hostPID: daemon.pid)
        let threadPlain = AgentMarker(kind: .codex, sessionID: threadHost.sessionID)
        let child = entry(2_201, "server", marker: threadHost, ports: ["8080"])
        let canonicalMetadata = Attribution.build(from: [daemon, child], now: now,
                                                 sessionFiles: [threadPlain: .init(modifiedAt: now)])
        precondition(canonicalMetadata.liveSessions.count == 1 && canonicalMetadata.leftoverSessions.isEmpty)
        let decoratedMetadata = Attribution.build(from: [daemon, child], now: now,
                                                 sessionFiles: [threadHost: .init(modifiedAt: now)])
        precondition(decoratedMetadata.liveSessions.count == 1 && decoratedMetadata.leftoverSessions.isEmpty)
        let duplicateMetadata = Attribution.build(from: [daemon, child], now: now,
                                                 sessionFiles: [threadPlain: .init(modifiedAt: now.addingTimeInterval(-1_200)),
                                                                threadHost: .init(modifiedAt: now)])
        precondition(duplicateMetadata.liveSessions.count == 1 && duplicateMetadata.leftoverSessions.isEmpty)
        print("PASS: detached live/dead/reused/wrong-kind/foreign hosts, birth identity guard, mixed host/no-host single session, future kinds, canonical daemon metadata")
    }

}
