import Foundation
import Darwin

// STUB with the final signatures. Worker "core" replaces the bodies; the UI worker must not edit this file.

enum Attribution {
    /// Full pipeline: ProcessService.snapshot() (with agent markers) → grouping into sessions.
    static func snapshot() -> AttributedSnapshot {
        build(from: ProcessService.snapshot(), now: Date())
    }

    /// Pure grouping logic, testable with synthetic entries.
    static func build(from processes: [ProcessEntry], now: Date) -> AttributedSnapshot {
        let servers = processes.filter { !$0.listeningPorts.isEmpty }
            .map { AttributedProcess(entry: $0, role: .server, depth: 0, tree: [$0]) }
        return AttributedSnapshot(liveSessions: [], leftoverSessions: [], otherServers: servers, all: processes)
    }
}

extension ProcessService {
    /// Stops every process in `tree` (children first): SIGTERM, wait up to `grace` seconds, then SIGKILL the survivors.
    /// Each entry is identity-checked (pid + start time + uid) before every signal, like `terminate`.
    static func stop(_ tree: [ProcessEntry], grace: TimeInterval = 3) async -> StopResult {
        var failed: [pid_t: String] = [:]
        var stopped: [pid_t] = []
        for entry in tree.reversed() {
            do { try terminate(entry); stopped.append(entry.pid) }
            catch { failed[entry.pid] = error.localizedDescription }
        }
        return StopResult(stopped: stopped, killed: [], failed: failed)
    }
}
