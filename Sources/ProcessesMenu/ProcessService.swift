import Foundation
import Darwin

enum ProcessService {
    static func details(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    static func snapshot() -> [ProcessEntry] {
        let ports = listeningPorts()
        // Leave room for processes created between the two calls.
        let capacity = max(Int(proc_listallpids(nil, 0)) + 256, 1024)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var owners: [uid_t: String] = [:]
        let argumentCapacity = argumentBufferCapacity()
        var markerCandidates: [pid_t: [AgentMarker]] = [:]
        let entries = pids.prefix(Int(count)).compactMap { pid -> ProcessEntry? in
            guard pid > 0, var info = details(pid) else { return nil }
            let name = withUnsafePointer(to: &info.pbi_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
            }
            let fallback = withUnsafePointer(to: &info.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
            }
            if owners[info.pbi_uid] == nil {
                owners[info.pbi_uid] = getpwuid(info.pbi_uid).map { String(cString: $0.pointee.pw_name) } ?? String(info.pbi_uid)
            }
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let hasMemory = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize
            let arguments = info.pbi_uid == getuid() ? processArguments(pid, capacity: argumentCapacity) : Arguments(command: "", markers: [])
            markerCandidates[pid] = arguments.markers
            return ProcessEntry(pid: pid, name: name.isEmpty ? fallback : name,
                                owner: owners[info.pbi_uid]!, uid: info.pbi_uid,
                                startedSeconds: info.pbi_start_tvsec,
                                startedMicroseconds: info.pbi_start_tvusec,
                                parentPID: pid_t(info.pbi_ppid), processGroup: pid_t(info.pbi_pgid),
                                residentBytes: hasMemory ? task.pti_resident_size : nil,
                                command: arguments.command, listeningPorts: ports[pid] ?? [],
                                workingDirectory: workingDirectory(pid), agentMarker: arguments.marker)
        }.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.pid < $1.pid : comparison == .orderedAscending
        }
        return resolvingMarkers(entries, candidates: markerCandidates)
    }

    /// Nested agents can inherit another agent's markers. Prefer the nearest live agent's kind;
    /// without ancestry, a Codex thread identifier takes priority over a general session identifier.
    static func resolvingMarkers(_ entries: [ProcessEntry], candidates: [pid_t: [AgentMarker]]) -> [ProcessEntry] {
        let byPID = Dictionary(entries.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.map { entry in
            let markers = candidates[entry.pid] ?? []
            guard Set(markers.map(\.kind)).count > 1 else { return entry }
            var current: ProcessEntry? = entry
            var seen: Set<pid_t> = []
            while let ancestor = current, ancestor.uid == entry.uid, seen.insert(ancestor.pid).inserted {
                guard ancestor.startedSeconds <= entry.startedSeconds else { break }
                if let kind = Attribution.agentKind(ancestor), !Attribution.isAgentHelper(ancestor),
                   let marker = markers.first(where: { $0.kind == kind }) {
                    var resolved = entry
                    resolved.agentMarker = marker
                    return resolved
                }
                current = byPID[ancestor.parentPID]
            }
            return entry
        }
    }

    static func workingDirectory(_ pid: pid_t) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// KERN_ARGMAX is shared by the snapshot; each owned process needs only one PROCARGS2 call.
    static func argumentBufferCapacity() -> Int {
        var maximum: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &maximum, &size, nil, 0) == 0, maximum > 0 else { return 262_144 }
        return Int(maximum)
    }

    static func commandLine(_ pid: pid_t) -> String {
        guard details(pid)?.pbi_uid == getuid() else { return "" }
        return processArguments(pid, capacity: argumentBufferCapacity()).command
    }

    struct Arguments {
        let command: String
        let markers: [AgentMarker]
        var marker: AgentMarker? { markers.first }
    }

    static func processArguments(_ pid: pid_t, capacity: Int) -> Arguments {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = capacity
        var bytes = [UInt8](repeating: 0, count: capacity)
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return Arguments(command: "", markers: []) }
        return parseArguments(bytes.prefix(size))
    }

    /// Never decode an environment entry before checking its key as bytes.
    static func parseArguments(_ bytes: ArraySlice<UInt8>) -> Arguments {
        guard bytes.count > MemoryLayout<Int32>.size else { return Arguments(command: "", markers: []) }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < bytes.count else { return Arguments(command: "", markers: []) }
        var offset = bytes.startIndex + MemoryLayout<Int32>.size
        while offset < bytes.endIndex && bytes[offset] != 0 { offset += 1 }
        while offset < bytes.endIndex && bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard offset < bytes.endIndex else { return Arguments(command: arguments.joined(separator: " "), markers: []) }
            let start = offset
            while offset < bytes.endIndex && bytes[offset] != 0 { offset += 1 }
            let argument = String(decoding: bytes[start..<offset], as: UTF8.self)
            arguments.append(argument.contains(where: { $0.isWhitespace }) ? "\"\(argument)\"" : argument)
            offset += 1
        }
        let allowed: [(key: [UInt8], kind: AgentKind)] = [
            (Array("CODEX_THREAD_ID=".utf8), .codex),
            (Array("CLAUDE_CODE_SESSION_ID=".utf8), .claude),
            (Array("CODEX_SESSION_ID=".utf8), .codex)
        ]
        var markers: [Int: AgentMarker] = [:]
        while offset < bytes.endIndex {
            let start = offset
            while offset < bytes.endIndex && bytes[offset] != 0 { offset += 1 }
            let entry = bytes[start..<offset]
            if entry.isEmpty { break } // environment terminator; do not scan Apple's trailing strings
            for (priority, item) in allowed.enumerated() where entry.starts(with: item.key) {
                let value = entry.dropFirst(item.key.count)
                if !value.isEmpty { markers[priority] = AgentMarker(kind: item.kind, sessionID: String(decoding: value, as: UTF8.self)) }
            }
            offset += 1
        }
        return Arguments(command: arguments.joined(separator: " "), markers: markers.keys.sorted().compactMap { markers[$0] })
    }

    static func listeningPorts() -> [pid_t: [String]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-Fpn"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseListeningPorts(String(decoding: data, as: UTF8.self))
    }

    static func parseListeningPorts(_ output: String) -> [pid_t: [String]] {
        var result: [pid_t: [String]] = [:]
        var pid: pid_t?
        for line in output.split(separator: "\n") {
            if line.first == "p" { pid = pid_t(line.dropFirst()) }
            if line.first == "n", let pid, let port = line.split(separator: ":").last,
               UInt16(port) != nil {
                let value = String(port)
                if !(result[pid] ?? []).contains(value) { result[pid, default: []].append(value) }
            }
        }
        return result.mapValues { $0.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) } }
    }

    static func terminate(_ process: ProcessEntry, force: Bool = false) throws {
        guard process.canTerminate else { throw Failure.forbidden }
        guard let current = details(process.pid),
              current.pbi_start_tvsec == process.startedSeconds,
              current.pbi_start_tvusec == process.startedMicroseconds,
              current.pbi_uid == process.uid else { throw Failure.gone }
        guard kill(process.pid, force ? SIGKILL : SIGTERM) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    enum Failure: LocalizedError {
        case forbidden, gone
        var errorDescription: String? {
            switch self {
            case .forbidden: "Этот процесс нельзя завершить из приложения."
            case .gone: "Процесс уже завершился или был заменён другим. Обновите список."
            }
        }
    }
}
