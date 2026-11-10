import Foundation
import Darwin

enum Attribution {
    /// Active-session transient commands become visible only after this age.
    static let activeProcessMinimumAge: TimeInterval = 20

    static func isApplicationProcess(_ entry: ProcessEntry) -> Bool {
        entry.pid == getpid() || (executable(entry.command) as NSString).lastPathComponent == "ProcessesMenu" ||
            (entry.command.isEmpty && entry.name == "ProcessesMenu")
    }

    /// hostPID is evidence about a session, never part of its identity.
    static func sessionIdentity(_ marker: AgentMarker) -> AgentMarker {
        AgentMarker(kind: marker.kind, sessionID: marker.sessionID)
    }

    struct SessionFile: Sendable {
        let modifiedAt: Date
        var projectPath: String = ""
    }

    static func snapshot() -> AttributedSnapshot {
        let processes = ProcessService.snapshot()
        let now = Date()
        return build(from: processes, now: now, sessionFiles: sessionFiles(for: processes))
    }

    /// The two-argument contract stays pure; disk metadata is injected only by snapshot().
    static func build(from processes: [ProcessEntry], now: Date) -> AttributedSnapshot {
        build(from: processes, now: now, sessionFiles: [:])
    }

    static func build(from processes: [ProcessEntry], now: Date,
                      sessionFiles: [AgentMarker: SessionFile]) -> AttributedSnapshot {
        let filesBySession = Dictionary(sessionFiles.map { (sessionIdentity($0.key), $0.value) }, uniquingKeysWith: { first, second in
            if first.modifiedAt != second.modifiedAt { return first.modifiedAt > second.modifiedAt ? first : second }
            return first.projectPath < second.projectPath ? second : first
        })
        let owned = processes.filter { $0.uid == getuid() && !isApplicationProcess($0) }
        let byPID = Dictionary(owned.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let agents = Dictionary(owned.compactMap { entry in
            agentKind(entry).map { (entry.pid, $0) }
        }, uniquingKeysWith: { first, _ in first })

        func ancestry(_ entry: ProcessEntry) -> [ProcessEntry] {
            var result: [ProcessEntry] = []
            var seen: Set<pid_t> = [entry.pid]
            var parent = entry.parentPID
            while parent > 1, seen.insert(parent).inserted, let next = byPID[parent] {
                // A reused parent PID cannot be the ancestor of an older child.
                guard next.startedSeconds <= entry.startedSeconds else { break }
                result.append(next)
                parent = next.parentPID
            }
            return result
        }
        let ancestors = Dictionary(owned.map { ($0.pid, ancestry($0)) }, uniquingKeysWith: { first, _ in first })
        // An agent often sets its session marker only in its children's environment.
        var agentMarkers: [pid_t: Set<AgentMarker>] = [:]
        var markerAgents: [AgentMarker: ProcessEntry] = [:]
        var hostAgents: [AgentMarker: ProcessEntry] = [:]
        for entry in owned {
            guard let rawMarker = entry.agentMarker else { continue }
            let marker = sessionIdentity(rawMarker)
            let chain = [entry] + (ancestors[entry.pid] ?? [])
            // Code mode hosts are implementation helpers, not proof that a CLI session is alive.
            if let agent = chain.first(where: { agents[$0.pid] == marker.kind && !isAgentHelper($0) }) {
                if markerAgents[marker] == nil || agent.pid < markerAgents[marker]!.pid {
                    markerAgents[marker] = agent
                }
            }
            if let pid = rawMarker.hostPID, pid > 1, let host = byPID[pid],
               agents[pid] == marker.kind, !isAgentHelper(host),
               host.startedSeconds < entry.startedSeconds ||
                (host.startedSeconds == entry.startedSeconds && host.startedMicroseconds <= entry.startedMicroseconds) {
                if hostAgents[marker] == nil || pid < hostAgents[marker]!.pid { hostAgents[marker] = host }
            }
        }
        // An explicit validated host wins even when the orchestrator detached its children.
        markerAgents.merge(hostAgents, uniquingKeysWith: { _, host in host })
        for (marker, agent) in markerAgents { agentMarkers[agent.pid, default: []].insert(marker) }
        struct Identity {
            let kind: AgentKind
            let marker: AgentMarker?
            let agent: ProcessEntry?
            var key: String { marker.map { "\(kind.rawValue):\($0.sessionID)" } ?? "\(kind.rawValue):pid:\(agent!.pid)" }
        }
        var identities: [String: Identity] = [:]
        var members: [String: [ProcessEntry]] = [:]
        var assigned: Set<pid_t> = []
        for entry in owned {
            let chain = [entry] + (ancestors[entry.pid] ?? [])
            let identity: Identity?
            if let rawMarker = chain.first(where: { $0.agentMarker != nil })?.agentMarker {
                let marker = sessionIdentity(rawMarker)
                identity = Identity(kind: marker.kind, marker: marker, agent: markerAgents[marker])
            } else if let agent = chain.first(where: { agents[$0.pid] != nil && !isAgentHelper($0) }),
                      let kind = agents[agent.pid] {
                let markers = agentMarkers[agent.pid] ?? []
                let marker = markers.count == 1 ? markers.first : nil
                identity = Identity(kind: kind, marker: marker, agent: agent)
            } else {
                identity = nil
            }
            guard let identity else { continue }
            identities[identity.key] = identity
            assigned.insert(entry.pid)
            if agents[entry.pid] == nil { members[identity.key, default: []].append(entry) }
        }
        var live: [AgentSession] = []
        var leftover: [AgentSession] = []
        for key in identities.keys.sorted() {
            let identity = identities[key]!
            let entries = (members[key] ?? []).sorted { $0.pid < $1.pid }
            let file = identity.marker.flatMap { filesBySession[$0] }
            let state: SessionState
            if let agent = identity.agent {
                if isCodexDaemon(agent) {
                    // A daemon's existence says nothing about a particular thread's activity.
                    let age = file.map { max(0, now.timeIntervalSince($0.modifiedAt)) }
                    // No file means unknown idle duration; never manufacture a last-active time.
                    state = age.map { $0 <= 600 ? .active : .idle(seconds: Int($0)) } ?? .idle(seconds: 0)
                } else { state = .active }
            } else { state = .ended }
            let items = grouped(entries).filter { item in
                guard state == .active, item.role == .other || item.role == .helper,
                      item.entry.listeningPorts.isEmpty else { return true }
                let started = Double(item.entry.startedSeconds) + Double(item.entry.startedMicroseconds) / 1_000_000
                return now.timeIntervalSince1970 - started >= activeProcessMinimumAge
            }
            let project = [identity.agent?.workingDirectory ?? "",
                           entries.first(where: { !$0.workingDirectory.isEmpty })?.workingDirectory ?? "",
                           file?.projectPath ?? ""].first(where: { !$0.isEmpty }) ?? ""
            let session = AgentSession(id: key, kind: identity.kind, sessionID: identity.marker?.sessionID,
                                       agentPID: identity.agent?.pid, projectPath: project == "/" ? "" : project,
                                       startedSeconds: ([identity.agent].compactMap { $0 } + entries).map(\.startedSeconds).min() ?? 0,
                                       state: state, processes: items)
            if state == .active { live.append(session) }
            else if !items.isEmpty { leftover.append(session) }
        }
        let other = processes.filter { !isApplicationProcess($0) && !assigned.contains($0.pid) && !$0.listeningPorts.isEmpty }
            .map { AttributedProcess(entry: $0, role: .server, depth: 0, tree: [$0]) }
        return AttributedSnapshot(liveSessions: live, leftoverSessions: leftover,
                                  otherServers: other, all: processes)
    }

    static func executable(_ command: String) -> String {
        let first: String
        if command.first == "\"" { first = String(command.dropFirst().prefix { $0 != "\"" }) }
        else { first = command.split(separator: " ").first.map(String.init) ?? "" }
        // setproctitle can replace argv[0] with "npm exec … --browser chrome".
        // Its arguments must not make npm itself look like a Chrome executable.
        return ProcessDisplayName.launchers.first(where: { first.hasPrefix($0 + " ") }) ?? first
    }

    static func agentKind(_ entry: ProcessEntry) -> AgentKind? {
        let name = entry.name.lowercased()
        let basename = (executable(entry.command) as NSString).lastPathComponent.lowercased()
        let names = [name, basename]
        if names.contains("claude") || names.contains("claude-code") { return .claude }
        if names.contains("codex") || names.contains("codex-code-mode-host") { return .codex }
        if names.contains("kimi") || names.contains("kimi-cli") { return .kimi }
        if names.contains("cursor") || names.contains("cursor-agent") { return .cursor }
        return nil
    }

    static func isAgentHelper(_ entry: ProcessEntry) -> Bool {
        entry.name.lowercased() == "codex-code-mode-host" || (executable(entry.command) as NSString).lastPathComponent == "codex-code-mode-host"
    }

    static func isCodexDaemon(_ entry: ProcessEntry) -> Bool {
        agentKind(entry) == .codex && executable(entry.command).contains("/app-server-daemon/")
    }

    static func role(_ entry: ProcessEntry) -> ProcessRole {
        let text = (entry.name + " " + entry.command).lowercased()
        // MCP's --browser chrome argument is not a browser executable.
        let nameAndExecutable = (entry.name + " " + executable(entry.command)).lowercased()
        if nameAndExecutable.contains("chrome") || nameAndExecutable.contains("chromium") || nameAndExecutable.contains("headless_shell") ||
            ((nameAndExecutable.contains("webkit") || nameAndExecutable.contains("firefox")) &&
             (text.contains("playwright") || text.contains("ms-playwright"))) { return .browser }
        if !entry.listeningPorts.isEmpty { return .server }
        let shellNames = ["sh", "bash", "zsh", "fish"]
        let isShell = shellNames.contains((executable(entry.command) as NSString).lastPathComponent.lowercased()) || shellNames.contains(entry.name.lowercased())
        // Shell payloads often contain inspection/test source mentioning MCP. They are wrappers,
        // not MCP servers; an actual MCP child still supplies the group's representative.
        if !isShell && (text.contains("@playwright/mcp") || text.contains("mcp-server") || text.contains("/mcp/") ||
            text.contains(" mcp ") || text.hasSuffix(" mcp")) { return .mcp }
        let name = entry.name.lowercased()
        if ["sh", "bash", "zsh", "fish", "npm", "npx", "env"].contains(name) ||
            text.hasPrefix("npm run ") || text.hasPrefix("npm exec ") { return .helper }
        return .other
    }

    static func rank(_ role: ProcessRole) -> Int {
        switch role {
        case .server: 0
        case .browser: 1
        case .other: 2
        case .helper: 3
        case .mcp: 4
        case .agent: 5
        }
    }

    /// Collapse wrappers into their meaningful child and keep browser helpers in one tree.
    /// Distinct servers/browsers/MCP branches remain individually stoppable.
    static func grouped(_ entries: [ProcessEntry]) -> [AttributedProcess] {
        let pids = Set(entries.map(\.pid))
        let children = Dictionary(grouping: entries, by: \.parentPID)
        var visited: Set<pid_t> = []
        struct Group {
            var entry: ProcessEntry
            var role: ProcessRole
            var tree: [ProcessEntry]
        }
        func walk(_ entry: ProcessEntry) -> [Group] {
            guard visited.insert(entry.pid).inserted else { return [] }
            let ownRole = role(entry)
            var groups = (children[entry.pid] ?? []).sorted { $0.pid < $1.pid }.flatMap { walk($0) }
            if ownRole == .other && groups.allSatisfy({ $0.role == .other || $0.role == .helper }) {
                return [Group(entry: entry, role: ownRole, tree: [entry] + groups.flatMap(\.tree))]
            }
            if ownRole == .helper || ownRole == .other {
                if !groups.isEmpty {
                    // Prefer a listening application over its npm/sh/node wrapper.
                    let best = groups.indices.min { rank(groups[$0].role) < rank(groups[$1].role) }!
                    groups[best].tree.insert(entry, at: 0)
                    return groups
                }
                return [Group(entry: entry, role: ownRole, tree: [entry])]
            }
            var current = Group(entry: entry, role: ownRole, tree: [entry])
            var separate: [Group] = []
            for group in groups {
                if group.role == .helper || group.role == .other || (ownRole == .browser && group.role == .browser) ||
                    (ownRole == .mcp && group.role == .mcp) {
                    current.tree += group.tree
                } else { separate.append(group) }
            }
            return [current] + separate
        }
        var groups: [Group] = []
        for entry in entries.filter({ !pids.contains($0.parentPID) }).sorted(by: { $0.pid < $1.pid }) { groups += walk(entry) }
        // A malformed/cyclic synthetic parent graph must still preserve each process once.
        for entry in entries where !visited.contains(entry.pid) { groups += walk(entry) }
        return groups.sorted {
            let left = rank($0.role), right = rank($1.role)
            return left == right ? $0.entry.pid < $1.entry.pid : left < right
        }.map { AttributedProcess(entry: $0.entry, role: $0.role, depth: 0, tree: $0.tree) }
    }

    /// Claude replaces '/' with '-'. Resolve existing directories to preserve hyphens in names;
    /// unavailable/ambiguous paths can only be reconstructed on a best-effort basis.
    static func claudeProjectPath(_ encoded: String, knownPaths: [String] = [],
                                  directoryExists: (String) -> Bool) -> String {
        if let known = knownPaths.sorted().first(where: { $0.replacingOccurrences(of: "/", with: "-") == encoded }) { return known }
        guard encoded.hasPrefix("-") else { return "" }
        let parts = encoded.dropFirst().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        var checks = 0
        func resolve(_ start: Int, _ parent: String) -> String? {
            guard start < parts.count else { return parent }
            for end in stride(from: parts.count, through: start + 1, by: -1) {
                let component = parts[start..<end].joined(separator: "-")
                guard !component.isEmpty else { continue }
                let candidate = parent + "/" + component
                checks += 1
                guard checks <= 256 else { return nil }
                if directoryExists(candidate), let path = resolve(end, candidate) { return path }
            }
            return nil
        }
        return resolve(0, "") ?? encoded.replacingOccurrences(of: "-", with: "/")
    }

    /// Only path and mtime are inspected. Session file contents are never opened.
    static func sessionFiles(for processes: [ProcessEntry]) -> [AgentMarker: SessionFile] {
        let wanted = Set(processes.compactMap { $0.agentMarker.map(sessionIdentity) })
        guard !wanted.isEmpty else { return [:] }
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let knownPaths = Array(Set(processes.filter { $0.uid == getuid() }.map(\.workingDirectory).filter { !$0.isEmpty }))
        var result: [AgentMarker: SessionFile] = [:]
        for (kind, relative) in [(AgentKind.codex, ".codex/sessions"), (.claude, ".claude/projects")] {
            let markers = wanted.filter { $0.kind == kind }
            guard !markers.isEmpty,
                  let files = manager.enumerator(at: home.appendingPathComponent(relative),
                                                 includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in files {
                guard url.pathExtension == "jsonl" else { continue }
                let filename = url.deletingPathExtension().lastPathComponent
                guard let marker = markers.first(where: {
                    kind == .codex ? filename.hasSuffix("-" + $0.sessionID) : filename == $0.sessionID
                }), let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                   values.isRegularFile == true, let modified = values.contentModificationDate else { continue }
                let project = kind == .claude ? claudeProjectPath(url.deletingLastPathComponent().lastPathComponent, knownPaths: knownPaths) { path in
                    var directory: ObjCBool = false
                    return manager.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
                } : ""
                if result[marker].map({ $0.modifiedAt < modified }) ?? true {
                    result[marker] = SessionFile(modifiedAt: modified, projectPath: project)
                }
            }
        }
        return result
    }
}

extension ProcessService {
    static func stop(_ tree: [ProcessEntry], grace: TimeInterval = 3) async -> StopResult {
        let unique = Dictionary(tree.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        func depth(_ entry: ProcessEntry) -> Int {
            var seen: Set<pid_t> = [entry.pid]
            var parent = entry.parentPID
            var depth = 0
            while let ancestor = unique[parent], seen.insert(parent).inserted {
                depth += 1
                parent = ancestor.parentPID
            }
            return depth
        }
        let ordered = unique.values.sorted {
            let left = depth($0), right = depth($1)
            return left == right ? $0.pid > $1.pid : left > right
        }
        func alive(_ entry: ProcessEntry) -> Bool {
            guard let info = details(entry.pid) else { return false }
            return info.pbi_start_tvsec == entry.startedSeconds && info.pbi_start_tvusec == entry.startedMicroseconds &&
                info.pbi_uid == entry.uid && info.pbi_status != UInt32(SZOMB)
        }
        var failed: [pid_t: String] = [:]
        var pending: [ProcessEntry] = []
        var stopped: [pid_t] = []
        var killed: [pid_t] = []
        for entry in ordered {
            guard entry.canTerminate else { failed[entry.pid] = Failure.forbidden.localizedDescription; continue }
            guard alive(entry) else { stopped.append(entry.pid); continue }
            do { try terminate(entry); pending.append(entry) }
            catch Failure.gone { stopped.append(entry.pid) }
            catch {
                // ESRCH can race with the identity check when a process exits on its own.
                if !alive(entry) { stopped.append(entry.pid) }
                else { failed[entry.pid] = error.localizedDescription }
            }
        }
        let duration = grace.isFinite ? max(0, grace) : 3
        let deadline = ContinuousClock.now.advanced(by: .seconds(duration))
        while !pending.isEmpty {
            pending = pending.filter { entry in
                if alive(entry) { return true }
                stopped.append(entry.pid)
                return false
            }
            if pending.isEmpty || ContinuousClock.now >= deadline { break }
            // Cancellation shortens the grace period but must not leave the tree half-stopped.
            do { try await Task.sleep(for: .milliseconds(25)) } catch { break }
        }
        for entry in pending {
            guard alive(entry) else { stopped.append(entry.pid); continue }
            do { try terminate(entry, force: true); killed.append(entry.pid) }
            catch Failure.gone { stopped.append(entry.pid) }
            catch {
                // ESRCH can race with the identity check when a process exits on its own.
                if !alive(entry) { stopped.append(entry.pid) }
                else { failed[entry.pid] = error.localizedDescription }
            }
        }
        return StopResult(stopped: stopped.sorted(), killed: killed.sorted(), failed: failed)
    }
}

extension ProcessEntry {
    /// Short task/application name. Positional values and arbitrary option values are never shown.
    var displayName: String { ProcessDisplayName.name(command: command, fallback: name) }
}

private enum ProcessDisplayName {
    static let launchers = ["npm", "npx", "pnpm", "yarn", "node", "nodejs", "bun", "bunx", "deno", "python", "python3", "ruby", "java"]
    /// Tokenize the quoted argv representation produced by ProcessService without executing a shell.
    static func words(_ command: String) -> [String] {
        var result: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped { word.append(character); escaped = false; continue }
            if character == "\\" && quote != "'" { escaped = true; continue }
            if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" { quote = character }
            else if character.isWhitespace {
                if !word.isEmpty { result.append(word); word = "" }
                if result.count >= 32 { break }
            } else { word.append(character) }
        }
        if escaped { word.append("\\") }
        if !word.isEmpty { result.append(word) }
        return result
    }

    static func name(command: String, fallback: String) -> String {
        var arguments = words(command)
        // npm/setproctitle may flatten the whole command into argv[0]. Only unwrap known
        // launchers; a real executable path containing spaces remains one token.
        if let title = arguments.first, launchers.contains(where: { title.hasPrefix($0 + " ") }) {
            arguments = words(title) + arguments.dropFirst()
        }
        guard let executable = arguments.first else { return shortened(fallback) }
        let binary = (executable as NSString).lastPathComponent
        let lower = binary.lowercased()
        let args = Array(arguments.dropFirst())
        let label: String?
        if ["npm", "npx", "pnpm", "yarn", "bunx"].contains(lower) {
            label = runner(lower, args)
        } else if lower.hasPrefix("python") || ["node", "nodejs", "bun", "deno", "ruby", "java"].contains(lower) {
            label = interpreter(lower, args)
        } else if let app = executable.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
            label = String(app.dropLast(4))
        } else {
            label = withSubcommand(script(binary), args)
        }
        return shortened(label?.isEmpty == false ? label! : fallback)
    }

    static func shortened(_ value: String) -> String {
        let clean = value.filter { !$0.isNewline && !($0.asciiValue.map({ $0 < 32 || $0 == 127 }) ?? false) }
        return clean.count <= 32 ? clean : String(clean.prefix(31)) + "…"
    }

    /// Use package identity for generic JS entrypoints such as vite/bin/vite.js and mcp/cli.js.
    static func script(_ path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        if let index = components.lastIndex(of: "node_modules"), index + 1 < components.count {
            let package = components[index + 1]
            if package == "@playwright", index + 2 < components.count, components[index + 2] == "mcp" { return "playwright-mcp" }
            if package != ".bin" {
                if package.hasPrefix("@"), index + 2 < components.count { return packageName(components[index + 2]) }
                return packageName(package)
            }
        }
        let basename = (path as NSString).lastPathComponent
        if basename == "cli.js" || basename == "index.js" || basename == "main.js" {
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if !parent.isEmpty && parent != "." { return packageName(parent) }
        }
        // Python/Ruby filenames retain their extension; JS CLI extensions add little information.
        if ["js", "mjs", "cjs", "jar"].contains((basename as NSString).pathExtension) {
            return (basename as NSString).deletingPathExtension
        }
        return packageName(basename)
    }

    static func packageName(_ value: String) -> String {
        if (value == "@playwright/mcp" || value.hasPrefix("@playwright/mcp@")) { return "playwright-mcp" }
        let unscoped = value.split(separator: "/").last.map(String.init) ?? value
        return unscoped.split(separator: "@", maxSplits: 1).first.map(String.init) ?? unscoped
    }

    static func withSubcommand(_ label: String, _ args: [String]) -> String {
        let allowed: [String: Set<String>] = [
            "next": ["dev", "start", "build"], "tsx": ["watch"],
            "vite": ["preview", "build"], "playwright": ["test", "show-report", "install"],
            "astro": ["dev", "preview", "build"], "nuxt": ["dev", "start", "build"],
            "vitest": ["run", "watch"], "webpack": ["serve", "watch"]
        ]
        if let first = args.first, allowed[label]?.contains(first) == true { return label + " " + first }
        return label
    }

    static func runner(_ binary: String, _ args: [String]) -> String? {
        var index = 0
        var package: String?
        while index < args.count {
            let arg = args[index]
            if arg == "--package" || arg == "-p" {
                guard index + 1 < args.count else { return nil }
                package = packageName(args[index + 1]); index += 2; continue
            }
            if arg.hasPrefix("--package=") { package = packageName(String(arg.dropFirst(10))); index += 1; continue }
            if ["--cache", "--prefix", "--cwd", "--registry", "--userconfig", "-C"].contains(arg) { index += 2; continue }
            if ["--", "-y", "--yes", "--no", "--silent", "--offline", "--prefer-offline", "--ignore-scripts"].contains(arg) ||
                (arg.hasPrefix("--") && arg.contains("=")) || arg == "exec" || arg == "dlx" { index += 1; continue }
            if arg.hasPrefix("-") { return package } // unknown option arity: never show its possible value
            if arg == "run" || arg == "run-script" {
                guard index + 1 < args.count else { return nil }
                // npm script names are command identities, not values of application options.
                return binary + " run " + script(args[index + 1])
            }
            let label = package ?? (arg.hasPrefix("@") ? packageName(arg) : script(arg))
            return withSubcommand(label, Array(args.dropFirst(index + 1)))
        }
        return package
    }

    static func interpreter(_ binary: String, _ args: [String]) -> String? {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if ["-e", "--eval", "--print", "-p", "-c"].contains(arg) || arg.hasPrefix("--eval=") { return nil }
            if arg == "-m", binary.hasPrefix("python") {
                guard index + 1 < args.count else { return nil }
                return withSubcommand(packageName(args[index + 1]), Array(args.dropFirst(index + 2)))
            }
            if arg == "-jar", binary == "java" {
                guard index + 1 < args.count else { return nil }
                return script(args[index + 1])
            }
            if ["--env-file", "--require", "-r", "--loader", "--import", "--conditions", "--inspect-port",
                "--cwd", "--title", "--config", "-C", "-X", "-W", "-cp", "-classpath", "--class-path", "--module-path"].contains(arg) { index += 2; continue }
            if ["--", "-I", "-u", "-B", "-E", "-s", "-S", "--watch", "--no-warnings", "--enable-source-maps", "--trace-warnings", "--inspect", "--inspect-brk", "-A", "--allow-net", "--allow-read", "--allow-env"].contains(arg) ||
                (arg.hasPrefix("--") && arg.contains("=")) ||
                (binary == "java" && (arg.hasPrefix("-X") || arg.hasPrefix("-D"))) ||
                (binary == "deno" && ["run", "task"].contains(arg)) ||
                (binary == "bun" && ["run", "x"].contains(arg)) { index += 1; continue }
            if arg.hasPrefix("-") { return nil }
            return withSubcommand(script(arg), Array(args.dropFirst(index + 1)))
        }
        return nil
    }
}
