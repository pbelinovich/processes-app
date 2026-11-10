import Foundation
import Darwin

// Standalone integration checks, runnable with Command Line Tools (no XCTest required).
@main
enum ProcessServiceChecks {
    static func main() throws {
        let snapshot = ProcessService.snapshot()
        guard let own = snapshot.first(where: { $0.pid == getpid() }) else {
            fatalError("Current process missing from snapshot")
        }
        precondition(!own.name.isEmpty && !own.canTerminate)
        precondition((own.residentBytes ?? 0) > 0)
        precondition(own.parentPID == getppid())
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
        print("PASS: RSS, parent PID, command, working directory, live TCP listener, port parser, self-protection, stale PID identity, SIGTERM, SIGKILL")
    }

    static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected operation to fail") }
        catch { /* expected */ }
    }
}
