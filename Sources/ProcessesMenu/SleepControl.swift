import Foundation

/// SleepDisabled is a system-wide setting, independent of the current power source.
struct SleepControl: Sendable {
    struct CommandResult: Sendable {
        let status: Int32
        let output: String
    }

    enum Failure: LocalizedError {
        case command(String)
        case verification

        var errorDescription: String? {
            switch self {
            case .command(let text): text
            case .verification: "macOS не применила настройку сна."
            }
        }
    }

    var run: @Sendable (String, [String]) async throws -> CommandResult = { executable, arguments in
        try await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }

    static func isDisabled(in output: String) -> Bool {
        output.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            return fields.count == 2 && fields[0] == "SleepDisabled" && fields[1] == "1"
        }
    }

    func read() async throws -> Bool {
        let result = try await run("/usr/bin/pmset", ["-g"])
        guard result.status == 0 else { throw Failure.command(result.output) }
        // macOS omits SleepDisabled entirely when it has never been set.
        return Self.isDisabled(in: result.output)
    }

    func setDisabled(_ disabled: Bool) async throws {
        let arguments = ["-k", "-n", "--", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]
        // Ignore cached sudo credentials: success must not depend on a temporary timestamp.
        var result = try await run("/usr/bin/sudo", arguments)
        if result.status != 0 {
            let script = Self.installScript(uid: getuid())
            let appleScript = "do shell script \"" + script
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\" with administrator privileges"
            let install = try await run("/usr/bin/osascript", ["-e", appleScript])
            guard install.status == 0 else {
                throw Failure.command(install.output.contains("-128") ? "Настройка доступа отменена. Настройка сна не изменена." : install.output)
            }
            result = try await run("/usr/bin/sudo", arguments)
        }
        guard result.status == 0 else { throw Failure.command(result.output) }
        guard try await read() == disabled else { throw Failure.verification }
    }

    static func installScript(uid: uid_t) -> String {
        // Numeric UID is the only substituted value. No writable helper executable, shell
        // wildcard or general pmset permission is granted. Root owns the validated rule.
        """
        set -eu
        rule=$(/usr/bin/mktemp /private/etc/sudoers.d/.processes_sleep.XXXXXX)
        trap '/bin/rm -f "$rule"' EXIT
        /usr/bin/printf '%s\\n' '#\(uid) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1' > "$rule"
        /usr/sbin/chown root:wheel "$rule"
        /bin/chmod 0440 "$rule"
        /usr/sbin/visudo -c -f "$rule"
        /bin/mv -f "$rule" /private/etc/sudoers.d/processes_sleep_\(uid)
        """
    }
}
