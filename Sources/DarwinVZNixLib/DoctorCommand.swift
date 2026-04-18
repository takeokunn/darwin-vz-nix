import ArgumentParser
import Foundation

public struct Doctor: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Diagnose host-side DHCP / bootpd / networking issues that block VM IP discovery"
    )

    public init() {}

    public func run() async throws {
        var results: [DoctorCheckResult] = []

        results.append(macOSVersionCheck())
        results.append(firewallGlobalStateCheck())
        results.append(firewallBootpdCheck())
        results.append(bootpdLaunchdCheck())
        results.append(bridgeInterfacesCheck())
        results.append(dhcpdLeasesCheck())
        results.append(bootpdLogCheck())

        print(DoctorChecks.renderReport(results))
        print("")
        print("Suggested remediation if VM cannot obtain an IP:")
        print("  sudo killall bootpd              # restart the on-demand DHCP server")
        print("  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblock /usr/libexec/bootpd")
        print("  Reboot the Mac as a last resort.")
        print("")
        print("See README 'Troubleshooting' section for details.")
    }

    // MARK: - Checks

    private func macOSVersionCheck() -> DoctorCheckResult {
        let v = ProcessInfo().operatingSystemVersion
        let label = "macOS version: \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        let note = HostInfo.isMacOS14_4OrLater
            ? "macOS >= 14.4 — use `sudo killall bootpd` (kickstart -k restricted for system services)"
            : "macOS < 14.4 — `sudo launchctl kickstart -kp system/com.apple.bootpd` is available"
        return DoctorCheckResult(label: label, status: .info, detail: [note])
    }

    private func firewallGlobalStateCheck() -> DoctorCheckResult {
        let (exit, stdout, _) = runProcess(
            "/usr/libexec/ApplicationFirewall/socketfilterfw",
            ["--getglobalstate"],
            useSudo: true
        )
        guard exit == 0 else {
            return DoctorCheckResult(
                label: "Application Firewall global state",
                status: .skipped,
                detail: ["Could not query firewall (sudo required)"]
            )
        }
        let state = DoctorChecks.parseFirewallGlobalState(stdout)
        var detail: [String] = [stdout.trimmingCharacters(in: .whitespacesAndNewlines)]
        if state == 0 {
            detail.append("Firewall is disabled — bootpd should not be blocked")
        }
        return DoctorCheckResult(
            label: "Application Firewall global state",
            status: .info,
            detail: detail
        )
    }

    private func firewallBootpdCheck() -> DoctorCheckResult {
        let (exit, stdout, _) = runProcess(
            "/usr/libexec/ApplicationFirewall/socketfilterfw",
            ["--getappblocked", "/usr/libexec/bootpd"],
            useSudo: true
        )
        guard exit == 0 else {
            return DoctorCheckResult(
                label: "bootpd firewall status (informational)",
                status: .skipped,
                detail: ["Could not query firewall (sudo required)"]
            )
        }
        let trimmed = DoctorChecks.trimFirewallAppOutput(stdout)
        return DoctorCheckResult(
            label: "bootpd firewall status (informational)",
            status: .info,
            detail: [
                trimmed,
                "This output is not a reliable pass/fail signal; interpret manually.",
            ]
        )
    }

    private func bootpdLaunchdCheck() -> DoctorCheckResult {
        let (exit, stdout, _) = runProcess(
            "/bin/launchctl",
            ["print", "system/com.apple.bootpd"],
            useSudo: true
        )
        guard exit == 0 else {
            return DoctorCheckResult(
                label: "bootpd launchd state",
                status: .skipped,
                detail: ["Could not query launchctl (sudo required or service unloaded)"]
            )
        }
        let (state, lastExit) = DoctorChecks.parseLaunchctlPrint(stdout)
        var detail: [String] = []
        if let state = state {
            detail.append("state = \(state)")
        }
        if let lastExit = lastExit {
            detail.append("last exit code = \(lastExit)")
        }
        if detail.isEmpty {
            detail.append("launchctl returned no state/exit info")
        }
        return DoctorCheckResult(label: "bootpd launchd state", status: .info, detail: detail)
    }

    private func bridgeInterfacesCheck() -> DoctorCheckResult {
        let bridges = HostInfo.bridgeInterfaces()
        if bridges.isEmpty {
            return DoctorCheckResult(
                label: "Host bridge interfaces",
                status: .warning,
                detail: ["No bridgeN interfaces found. vmnet has not created one yet (start VM first)."]
            )
        }
        return DoctorCheckResult(
            label: "Host bridge interfaces",
            status: .ok,
            detail: ["Found: \(bridges.joined(separator: ", "))"]
        )
    }

    private func dhcpdLeasesCheck() -> DoctorCheckResult {
        let path = "/var/db/dhcpd_leases"
        let exists = FileManager.default.fileExists(atPath: path)
        guard exists else {
            return DoctorCheckResult(
                label: "DHCP lease database",
                status: .info,
                detail: ["\(path) does not exist yet — expected before first VM start"]
            )
        }
        let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let count = DoctorChecks.countLeaseEntries(content)
        let status = DoctorChecks.classifyLeaseFileSize(entryCount: count, exists: true)
        return DoctorCheckResult(
            label: "DHCP lease database",
            status: status,
            detail: ["\(path): \(count) lease entries"]
        )
    }

    private func bootpdLogCheck() -> DoctorCheckResult {
        let (exit, stdout, _) = runProcess(
            "/usr/bin/log",
            ["show", "--predicate", "process == \"bootpd\"", "--last", "5m", "--style", "compact"],
            useSudo: false,
            timeout: 10
        )
        if exit == -2 {
            return DoctorCheckResult(
                label: "Recent bootpd log (last 5m)",
                status: .skipped,
                detail: ["`log show` timed out after 10s — system log daemon may be slow"]
            )
        }
        guard exit == 0 else {
            return DoctorCheckResult(
                label: "Recent bootpd log (last 5m)",
                status: .skipped,
                detail: ["`log show` exited with non-zero status"]
            )
        }
        let lines = stdout
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let tail = Array(lines.suffix(5))
        if tail.isEmpty {
            return DoctorCheckResult(
                label: "Recent bootpd log (last 5m)",
                status: .info,
                detail: ["No bootpd log entries in last 5 minutes."]
            )
        }
        return DoctorCheckResult(
            label: "Recent bootpd log (last 5m)",
            status: .info,
            detail: tail
        )
    }

    // MARK: - Subprocess helper

    /// Runs a process and captures stdout/stderr. Uses `sudo -n` when useSudo=true,
    /// matching the existing passwordless-sudo precedent at StartCommand.cleanStaleLockFiles.
    /// When `timeout` is non-nil, the process is terminated after that many seconds and
    /// the result is returned with exit=-2.
    private func runProcess(_ executable: String, _ args: [String], useSudo: Bool, timeout: TimeInterval? = nil) -> (exit: Int32, stdout: String, stderr: String) {
        let process = Process()
        if useSudo {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", executable] + args
        } else {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return (-1, "", String(describing: error))
        }

        var timedOut = false
        if let timeout = timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                timedOut = true
                process.terminate()
                process.waitUntilExit()
            }
        } else {
            process.waitUntilExit()
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if timedOut {
            return (-2, stdout, stderr)
        }
        return (process.terminationStatus, stdout, stderr)
    }
}
