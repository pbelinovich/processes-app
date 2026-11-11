import Foundation

actor SleepCommands {
    var disabled = false
    var cancel = false
    var ignoreWrite = false
    var installed = false
    var authorizationCount = 0

    func configure(cancel: Bool = false, ignoreWrite: Bool = false) {
        self.cancel = cancel
        if cancel { installed = false }
        self.ignoreWrite = ignoreWrite
    }

    func run(_ executable: String, _ arguments: [String]) -> SleepControl.CommandResult {
        if executable == "/usr/bin/pmset" {
            precondition(arguments == ["-g"], "Reads must never change settings")
            return .init(status: 0, output: "System-wide power settings:\n SleepDisabled \(disabled ? 1 : 0)\n")
        }
        if executable == "/usr/bin/sudo" {
            precondition(Array(arguments.prefix(6)) == ["-k", "-n", "--", "/usr/bin/pmset", "-a", "disablesleep"])
            precondition(arguments.count == 7 && ["0", "1"].contains(arguments[6]))
            guard installed else { return .init(status: 1, output: "sudo: a password is required") }
            if !ignoreWrite { disabled = arguments[6] == "1" }
            return .init(status: 0, output: "")
        }
        precondition(executable == "/usr/bin/osascript")
        precondition(arguments.count == 2 && arguments[0] == "-e")
        precondition(arguments[1].contains("with administrator privileges"))
        precondition(arguments[1].contains("/usr/sbin/visudo -c -f"))
        precondition(arguments[1].contains("NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"))
        authorizationCount += 1
        if cancel { return .init(status: 1, output: "User canceled. (-128)") }
        installed = true
        return .init(status: 0, output: "")
    }
}

@main
enum SleepControlChecks {
    static func main() async throws {
        precondition(!SleepControl.isDisabled(in: "System-wide power settings:\nCurrently in use:\n sleep 0"))
        precondition(SleepControl.isDisabled(in: " SleepDisabled\t1\n"))
        precondition(!SleepControl.isDisabled(in: " SleepDisabled 0\n"))
        let commands = SleepCommands()
        let control = SleepControl(run: { executable, arguments in await commands.run(executable, arguments) })
        let initial = try await control.read()
        precondition(!initial)
        try await control.setDisabled(true)
        let enabled = try await control.read()
        precondition(enabled)
        try await control.setDisabled(false)
        let restored = try await control.read()
        precondition(!restored)
        let promptCount = await commands.authorizationCount
        precondition(promptCount == 1, "Only the first toggle must request authorization")
        let script = SleepControl.installScript(uid: 501)
        precondition(script.contains("#501 ALL=(root) NOPASSWD:"))
        precondition(script.contains("/private/etc/sudoers.d/processes_sleep_501"))
        precondition(!script.contains("NOPASSWD: ALL") && !script.contains("pmset *"))
        let shellCheck = try await SleepControl().run("/bin/sh", ["-n", "-c", script])
        precondition(shellCheck.status == 0, "Installer shell syntax must be valid")
        let ruleLine = script.split(separator: "\n").first { $0.contains("NOPASSWD:") }!
        let rule = String(ruleLine.split(separator: "'", omittingEmptySubsequences: false)[3])
        let temporaryRule = FileManager.default.temporaryDirectory.appendingPathComponent("processes-sleep-rule-" + UUID().uuidString)
        try (rule + "\n").write(to: temporaryRule, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temporaryRule) }
        let ruleCheck = try await SleepControl().run("/usr/sbin/visudo", ["-c", "-f", temporaryRule.path])
        precondition(ruleCheck.status == 0, "Sudoers rule must pass visudo: " + ruleCheck.output)
        await commands.configure(cancel: true)
        do {
            try await control.setDisabled(true)
            fatalError("Cancelled authorization must fail")
        } catch SleepControl.Failure.command(let message) {
            precondition(message.contains("отменена"))
        }
        let afterCancel = try await control.read()
        precondition(!afterCancel)
        await commands.configure(ignoreWrite: true)
        do {
            try await control.setDisabled(true)
            fatalError("Unapplied setting must fail verification")
        } catch SleepControl.Failure.verification {}
        print("PASS: sleep setting read, authorized enable/disable, cancellation and verification (no system changes)")
    }
}
