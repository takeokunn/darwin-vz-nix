import ArgumentParser
import Darwin
import Foundation

public struct Doctor: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Diagnose host-side DHCP / bootpd / networking / Nix store issues that block VM usage"
    )

    @Flag(name: .long, help: "Output the diagnostic report as JSON")
    var json: Bool = false

    public init() {}

    public func run() async throws {
        var results: [DoctorCheckResult] = []

        results.append(macOSVersionCheck())
        results.append(firewallGlobalStateCheck())
        results.append(firewallBootpdCheck())
        results.append(bootpdLaunchdCheck())
        results.append(bridgeInterfacesCheck())
        results.append(dhcpdLeasesCheck())
        results.append(nixStoreLockCheck())
        results.append(bootpdLogCheck())

        if json {
            let report = DoctorReport(
                version: BuildInfo.version,
                overall: DoctorChecks.overallStatus(results),
                checks: results
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }

        print("darwin-vz-nix \(BuildInfo.version)")
        print("")
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
        let (exit, stdout, _) = Doctor.runProcess(
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
        let (exit, stdout, _) = Doctor.runProcess(
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
        let (exit, stdout, _) = Doctor.runProcess(
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
        if let state {
            detail.append("state = \(state)")
        }
        if let lastExit {
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

    private func nixStoreLockCheck() -> DoctorCheckResult {
        let storeURL = URL(fileURLWithPath: "/nix/store", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: storeURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return DoctorCheckResult(
                label: "Nix store stale lock files",
                status: .skipped,
                detail: ["/nix/store is not available on this host"]
            )
        }

        do {
            let entries = try FileManager.default.contentsOfDirectory(
                at: storeURL,
                includingPropertiesForKeys: nil
            )
            let staleLockCount = entries.reduce(0) { count, url in
                guard
                    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                    let fileType = attributes[.type] as? FileAttributeType,
                    let fileSize = attributes[.size] as? NSNumber,
                    let permissions = attributes[.posixPermissions] as? NSNumber
                else {
                    return count
                }

                return count + (DoctorChecks.isPotentialStaleNixStoreLock(
                    name: url.lastPathComponent,
                    fileType: fileType,
                    fileSize: fileSize.uint64Value,
                    permissions: permissions.intValue
                ) ? 1 : 0)
            }
            let status = DoctorChecks.classifyStaleNixStoreLockCount(staleLockCount)
            if status == .warning {
                return DoctorCheckResult(
                    label: "Nix store stale lock files",
                    status: status,
                    detail: [
                        "Found \(staleLockCount) zero-byte 0600 *.lock file(s) in /nix/store",
                        "Inspect before deleting: sudo find /nix/store -maxdepth 1 -name '*.lock' -size 0 -perm 600 -ls",
                    ]
                )
            }
            return DoctorCheckResult(
                label: "Nix store stale lock files",
                status: status,
                detail: ["No zero-byte 0600 *.lock files found in /nix/store"]
            )
        } catch {
            return DoctorCheckResult(
                label: "Nix store stale lock files",
                status: DoctorChecks.classifyStaleNixStoreLockCount(nil),
                detail: ["Could not scan /nix/store: \(error.localizedDescription)"]
            )
        }
    }

    private func bootpdLogCheck() -> DoctorCheckResult {
        let (exit, stdout, _) = Doctor.runProcess(
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
        let lines = DoctorChecks.extractBootpdLogLines(stdout)
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

    /// Runs a process and captures stdout/stderr. Uses `sudo -n` when useSudo=true.
    /// When `timeout` is non-nil, the process is terminated after that many seconds and
    /// the result is returned with exit=-2.
    static func runProcess(_ executable: String, _ args: [String], useSudo: Bool, timeout: TimeInterval? = nil) -> (exit: Int32, stdout: String, stderr: String) {
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

        let terminationSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminationSemaphore.signal()
        }

        do {
            try process.run()
        } catch {
            return (-1, "", String(describing: error))
        }

        let outputGroup = DispatchGroup()
        let stdoutQueue = DispatchQueue(label: "com.darwin-vz-nix.doctor.stdout")
        let stderrQueue = DispatchQueue(label: "com.darwin-vz-nix.doctor.stderr")
        var stdoutData = Data()
        var stderrData = Data()

        outputGroup.enter()
        stdoutQueue.async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }

        outputGroup.enter()
        stderrQueue.async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }

        var timedOut = false
        if let timeout {
            let timeoutMilliseconds = max(0, Int((timeout * 1000).rounded(.up)))
            if terminationSemaphore.wait(timeout: .now() + .milliseconds(timeoutMilliseconds)) == .timedOut {
                timedOut = true
                process.terminate()
                if terminationSemaphore.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
            }
        } else {
            terminationSemaphore.wait()
        }

        process.waitUntilExit()
        outputGroup.wait()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if timedOut {
            return (-2, stdout, stderr)
        }
        return (process.terminationStatus, stdout, stderr)
    }
}
