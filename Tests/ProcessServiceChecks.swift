import Foundation
import Darwin

// Standalone integration checks, runnable with Command Line Tools (no XCTest required).
@main
enum ProcessServiceChecks {
    static func main() async throws {
        if CommandLine.arguments.contains("--marker-child") { sleep(60); return }
        let snapshot = ProcessService.snapshot()
        guard let own = snapshot.first(where: { $0.pid == getpid() }) else {
            fatalError("Current process missing from snapshot")
        }
        precondition(!own.name.isEmpty && !own.canTerminate)
        precondition((own.residentBytes ?? 0) > 0)
        precondition(own.parentPID == getppid())
        precondition(own.processGroup == getpgrp())
        precondition(!own.command.isEmpty)
        precondition(own.workingDirectory == FileManager.default.currentDirectoryPath)
        expectFailure { try ProcessService.terminate(own) }

        let parsed = ProcessService.parseListeningPorts("p42\nn127.0.0.1:3000\nn[::1]:3000\nn*:8080\np43\nn*:9000\n")
        precondition(parsed[42] == ["3000", "8080"] && parsed[43] == ["9000"])
        let server = socket(AF_INET, SOCK_STREAM, 0)
        precondition(server >= 0)
        defer { close(server) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        precondition(bound == 0 && listen(server, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &length) }
        }
        precondition(found == 0)
        let port = String(UInt16(bigEndian: address.sin_port))
        precondition(ProcessService.listeningPorts()[getpid()]?.contains(port) == true)

        for force in [false, true] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["30"]
            try child.run()
            defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
            guard let entry = ProcessService.snapshot().first(where: { $0.pid == child.processIdentifier }) else {
                fatalError("Child process missing from snapshot")
            }
            let stale = ProcessEntry(pid: entry.pid, name: entry.name, owner: entry.owner, uid: entry.uid,
                                     startedSeconds: entry.startedSeconds + 1, startedMicroseconds: entry.startedMicroseconds)
            expectFailure { try ProcessService.terminate(stale, force: force) }
            precondition(child.isRunning)
            try ProcessService.terminate(entry, force: force)
            child.waitUntilExit()
            precondition(child.terminationReason == .uncaughtSignal)
            precondition(child.terminationStatus == (force ? SIGKILL : SIGTERM))
        }
        checkMessagingSocketParser()
        try await checkMarkersAndStopping()
        print("PASS: RSS, parent PID, PGID, command, cwd, TCP listener, whitelist parser, self/stale identity protection, inherited marker, child-first tree stop, TERM-to-KILL escalation")
    }

    static func checkMarkersAndStopping() async throws {
        // A synthetic byte buffer proves that only the whitelist's values reach the result.
        var bytes = withUnsafeBytes(of: Int32(2)) { Array($0) }
        bytes += Array("/bin/sleep\0\0/bin/sleep\060\0UNRELATED_SECRET=not-an-argument\0CODEX_SESSION_ID=fallback\0CODEX_THREAD_ID=preferred\0\0".utf8)
        let parsed = ProcessService.parseArguments(bytes[...])
        precondition(parsed.command == "/bin/sleep 60")
        precondition(parsed.marker == AgentMarker(kind: .codex, sessionID: "preferred"))
        var claudeBytes = withUnsafeBytes(of: Int32(1)) { Array($0) }
        claudeBytes += Array("/bin/sleep\0\0/bin/sleep\0CLAUDECODE=1\0CLAUDE_CODE_SESSION_ID=synthetic\0UNRELATED_SECRET=ignored\0".utf8)
        precondition(ProcessService.parseArguments(claudeBytes[...]).marker == AgentMarker(kind: .claude, sessionID: "synthetic"))

        let markerChild = Process()
        markerChild.executableURL = URL(fileURLWithPath: "/bin/sleep")
        markerChild.arguments = ["60"]
        let marker = AgentMarker(kind: .codex, sessionID: "test-" + UUID().uuidString)
        // Supply a minimal environment instead of copying the test runner's environment.
        markerChild.environment = ["CODEX_THREAD_ID": marker.sessionID, "UNRELATED_SECRET": "synthetic"]
        try markerChild.run()
        let marked = ProcessService.snapshot().first { $0.pid == markerChild.processIdentifier }!
        defer { try? ProcessService.terminate(marked, force: true); markerChild.waitUntilExit() }
        if marked.agentMarker == nil {
            print("SKIP: /bin/sleep environment is omitted by KERN_PROCARGS2 on this host; verify marker on the test executable instead")
        } else { precondition(marked.agentMarker == marker) }
        precondition(marked.processGroup == getpgid(marked.pid))
        let markerStop = await ProcessService.stop([marked], grace: 1)
        precondition(markerStop.stopped == [marked.pid] && markerStop.killed.isEmpty && markerStop.failed.isEmpty)
        markerChild.waitUntilExit()

        let unrestricted = Process()
        unrestricted.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        unrestricted.arguments = ["--marker-child"]
        unrestricted.environment = ["CODEX_THREAD_ID": marker.sessionID, "UNRELATED_SECRET": "synthetic",
                                    "CLAUDE_CODE_SESSION_ID": "synthetic-host-child",
                                    "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/synthetic/\(getpid()).sock"]
        try unrestricted.run()
        let unrestrictedEntry = ProcessService.snapshot().first { $0.pid == unrestricted.processIdentifier }!
        defer { try? ProcessService.terminate(unrestrictedEntry, force: true); unrestricted.waitUntilExit() }
        precondition(unrestrictedEntry.agentMarker == marker)
        let inherited = ProcessService.processArguments(unrestrictedEntry.pid, capacity: ProcessService.argumentBufferCapacity())
        precondition(inherited.markers.first { $0.kind == .claude }?.hostPID == getpid())
        let staleChild = ProcessEntry(pid: unrestrictedEntry.pid, name: "stale", owner: "synthetic", uid: getuid(),
                                      startedSeconds: unrestrictedEntry.startedSeconds + 1, startedMicroseconds: 0)
        let staleStop = await ProcessService.stop([staleChild], grace: 0)
        precondition(staleStop.killed.isEmpty && staleStop.failed.isEmpty && unrestricted.isRunning)
        let foreign = ProcessEntry(pid: unrestrictedEntry.pid, name: "foreign", owner: "synthetic", uid: getuid() + 1,
                                   startedSeconds: unrestrictedEntry.startedSeconds, startedMicroseconds: unrestrictedEntry.startedMicroseconds)
        let initProcess = ProcessEntry(pid: 1, name: "launchd", owner: "synthetic", uid: getuid(),
                                       startedSeconds: 0, startedMicroseconds: 0)
        let forbidden = await ProcessService.stop([foreign, initProcess], grace: 0)
        precondition(forbidden.failed.count == 2 && forbidden.stopped.isEmpty && forbidden.killed.isEmpty && unrestricted.isRunning)
        let unrestrictedResult = await ProcessService.stop([unrestrictedEntry], grace: 1)
        precondition(unrestrictedResult.failed.isEmpty && unrestrictedResult.stopped == [unrestrictedEntry.pid])
        unrestricted.waitUntilExit()

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 60 & first=$!; sleep 60 & second=$!; printf '%s %s\\n' \"$first\" \"$second\"; wait"]
        let output = Pipe()
        shell.standardOutput = output
        try shell.run()
        let line = output.fileHandleForReading.availableData
        let childPIDs = String(decoding: line, as: UTF8.self).split(whereSeparator: { $0.isWhitespace }).compactMap { pid_t($0) }
        precondition(childPIDs.count == 2)
        let ownPIDs = Set(childPIDs + [shell.processIdentifier])
        let tree = ProcessService.snapshot().filter { ownPIDs.contains($0.pid) }
        defer {
            for entry in tree { try? ProcessService.terminate(entry, force: true) }
            shell.waitUntilExit()
        }
        precondition(tree.count == 3)
        // Input order deliberately does not encode the parent tree's depth.
        let result = await ProcessService.stop(tree.sorted { $0.pid < $1.pid }, grace: 1)
        precondition(result.failed.isEmpty && result.killed.isEmpty && Set(result.stopped) == ownPIDs)
        shell.waitUntilExit()
        for entry in tree {
            precondition(ProcessService.details(entry.pid).map { $0.pbi_status == UInt32(SZOMB) } ?? true)
        }

        let stubborn = Process()
        stubborn.executableURL = URL(fileURLWithPath: "/bin/sh")
        stubborn.arguments = ["-c", "trap '' TERM; printf 'ready\\n'; exec /bin/sleep 60"]
        let ready = Pipe()
        stubborn.standardOutput = ready
        try stubborn.run()
        precondition(!ready.fileHandleForReading.availableData.isEmpty)
        let stubbornEntry = ProcessService.snapshot().first { $0.pid == stubborn.processIdentifier }!
        defer { try? ProcessService.terminate(stubbornEntry, force: true); stubborn.waitUntilExit() }
        let escalated = await ProcessService.stop([stubbornEntry], grace: 0.1)
        precondition(escalated.killed == [stubbornEntry.pid] && escalated.failed.isEmpty)
        stubborn.waitUntilExit()
        precondition(stubborn.terminationStatus == SIGKILL)

        let protected = await ProcessService.stop([ProcessService.snapshot().first { $0.pid == getpid() }!], grace: 0)
        precondition(protected.failed[getpid()] != nil && protected.stopped.isEmpty && protected.killed.isEmpty)
    }

    static func checkMessagingSocketParser() {
        func parse(_ environment: [String]) -> ProcessService.Arguments {
            var bytes = withUnsafeBytes(of: Int32(1)) { Array($0) }
            bytes += Array("/bin/sleep\0\0/bin/sleep\0".utf8)
            for entry in environment { bytes += entry.utf8; bytes.append(0) }
            bytes.append(0)
            return ProcessService.parseArguments(bytes[...])
        }
        let key = "CLAUDE_CODE_MESSAGING_SOCKET="
        for environment in [
            [key + "/tmp/synthetic-private-prefix/14225.sock", "CLAUDE_CODE_SESSION_ID=synthetic"],
            ["CLAUDE_CODE_SESSION_ID=synthetic", key + "/tmp/synthetic-private-prefix/14225.sock"]
        ] {
            let parsed = parse(environment)
            precondition(parsed.marker == AgentMarker(kind: .claude, sessionID: "synthetic", hostPID: 14_225))
            precondition(parsed.command == "/bin/sleep" && !parsed.command.contains("synthetic-private-prefix"))
        }
        let invalid = ["/tmp/not-numeric.sock", "/tmp/14225.sock.backup", "/tmp/.sock", "/tmp/0.sock", "/tmp/1.sock",
                       "/tmp/-14225.sock", "/tmp/+14225.sock", "/tmp/14225x.sock", "/tmp/2147483648.sock",
                       "/tmp/999999999999999999999999.sock", "/tmp/14225.sock/", "/tmp/ 14225.sock"]
        for value in invalid {
            precondition(parse(["CLAUDE_CODE_SESSION_ID=synthetic", key + value]).marker?.hostPID == nil)
        }
        precondition(parse([key + "/tmp/14225.sock"]).marker == nil)
        let mixed = parse([key + "/tmp/14225.sock", "CODEX_THREAD_ID=codex-synthetic", "CLAUDE_CODE_SESSION_ID=claude-synthetic"])
        precondition(mixed.markers.first { $0.kind == .codex }?.hostPID == nil)
        precondition(mixed.markers.first { $0.kind == .claude }?.hostPID == 14_225)
        print("PASS: byte-only socket PID extraction, key order, malformed/overflow PID rejection, kind isolation; socket values never decoded")
    }

    static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected operation to fail") }
        catch { /* expected */ }
    }
}
