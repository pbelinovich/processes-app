import Foundation
import Darwin

enum Attribution {
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
        let owned = processes.filter { $0.uid == getuid() }
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
        for entry in owned {
            guard let marker = entry.agentMarker else { continue }
            let chain = [entry] + (ancestors[entry.pid] ?? [])
            // Code mode hosts are implementation helpers, not proof that a CLI session is alive.
            if let agent = chain.first(where: { agents[$0.pid] == marker.kind && !isAgentHelper($0) }) {
                agentMarkers[agent.pid, default: []].insert(marker)
                if markerAgents[marker] == nil || agent.pid < markerAgents[marker]!.pid {
                    markerAgents[marker] = agent
                }
            }
        }
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
            if let marker = chain.first(where: { $0.agentMarker != nil })?.agentMarker {
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
            let items = grouped(entries)
            let file = identity.marker.flatMap { sessionFiles[$0] }
            let state: SessionState
            if let agent = identity.agent {
                if isCodexDaemon(agent) {
                    // A daemon's existence says nothing about a particular thread's activity.
                    let age = file.map { max(0, Int(now.timeIntervalSince($0.modifiedAt))) }
                    state = age.map { $0 <= 600 ? .active : .idle(seconds: $0) } ?? .idle(seconds: 600)
                } else { state = .active }
            } else { state = .ended }
            let project = [identity.agent?.workingDirectory ?? "",
                           entries.first(where: { !$0.workingDirectory.isEmpty })?.workingDirectory ?? "",
                           file?.projectPath ?? ""].first(where: { !$0.isEmpty }) ?? ""
            let session = AgentSession(id: key, kind: identity.kind, sessionID: identity.marker?.sessionID,
                                       agentPID: identity.agent?.pid, projectPath: project,
                                       startedSeconds: ([identity.agent].compactMap { $0 } + entries).map(\.startedSeconds).min() ?? 0,
                                       state: state, processes: items)
            if state == .active { live.append(session) }
            else if !items.isEmpty { leftover.append(session) }
        }
        let other = processes.filter { !assigned.contains($0.pid) && !$0.listeningPorts.isEmpty }
            .map { AttributedProcess(entry: $0, role: .server, depth: 0, tree: [$0]) }
        return AttributedSnapshot(liveSessions: live, leftoverSessions: leftover,
                                  otherServers: other, all: processes)
    }

    static func agentKind(_ entry: ProcessEntry) -> AgentKind? {
        let name = entry.name.lowercased()
        let executable = entry.command.split(separator: " ").first.map(String.init) ?? ""
        let basename = (executable.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) as NSString).lastPathComponent.lowercased()
        let names = [name, basename]
        if names.contains("claude") || names.contains("claude-code") { return .claude }
        if names.contains("codex") || names.contains("codex-code-mode-host") { return .codex }
        if names.contains("kimi") || names.contains("kimi-cli") { return .kimi }
        if names.contains("cursor") || names.contains("cursor-agent") { return .cursor }
        return nil
    }

    static func isAgentHelper(_ entry: ProcessEntry) -> Bool {
        entry.name.lowercased() == "codex-code-mode-host" || entry.command.split(separator: " ").first?.hasSuffix("/codex-code-mode-host") == true
    }

    static func isCodexDaemon(_ entry: ProcessEntry) -> Bool {
        agentKind(entry) == .codex && entry.command.contains("/app-server-daemon/")
    }

    static func role(_ entry: ProcessEntry) -> ProcessRole {
        let text = (entry.name + " " + entry.command).lowercased()
        if text.contains("chrome") || text.contains("chromium") || text.contains("headless_shell") ||
            ((text.contains("webkit") || text.contains("firefox")) &&
             (text.contains("playwright") || text.contains("ms-playwright"))) { return .browser }
        if !entry.listeningPorts.isEmpty { return .server }
        if text.contains("@playwright/mcp") || text.contains("mcp-server") || text.contains("/mcp/") ||
            text.contains(" mcp ") || text.hasSuffix(" mcp") { return .mcp }
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

    /// Only path and mtime are inspected. Session file contents are never opened.
    static func sessionFiles(for processes: [ProcessEntry]) -> [AgentMarker: SessionFile] {
        let wanted = Set(processes.compactMap(\.agentMarker))
        guard !wanted.isEmpty else { return [:] }
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
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
                // Claude's project folder encodes '/' as '-'; this is necessarily lossy for names containing '-'.
                let project = kind == .claude ? url.deletingLastPathComponent().lastPathComponent.replacingOccurrences(of: "-", with: "/") : ""
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
            catch { failed[entry.pid] = error.localizedDescription }
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
            catch { failed[entry.pid] = error.localizedDescription }
        }
        return StopResult(stopped: stopped.sorted(), killed: killed.sorted(), failed: failed)
    }
}
