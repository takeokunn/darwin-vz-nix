@testable import DarwinVZNixLib
import Testing

struct DoctorChecksTests {
    // MARK: - parseFirewallGlobalState

    @Test
    func firewallStateDisabled() {
        let out = "Firewall is disabled. (State = 0)"
        #expect(DoctorChecks.parseFirewallGlobalState(out) == 0)
    }

    @Test
    func firewallStateEnabled() {
        let out = "Firewall is enabled. (State = 1)"
        #expect(DoctorChecks.parseFirewallGlobalState(out) == 1)
    }

    @Test
    func firewallStateSpecificServices() {
        let out = "Firewall is on for specific services. (State = 2)"
        #expect(DoctorChecks.parseFirewallGlobalState(out) == 2)
    }

    @Test
    func firewallStateUnparseable() {
        #expect(DoctorChecks.parseFirewallGlobalState("unexpected format") == nil)
    }

    @Test
    func firewallStateEmpty() {
        #expect(DoctorChecks.parseFirewallGlobalState("") == nil)
    }

    @Test
    func firewallStateNoDigit() {
        #expect(DoctorChecks.parseFirewallGlobalState("State = abc") == nil)
    }

    @Test
    func firewallStateMultiDigit() {
        #expect(DoctorChecks.parseFirewallGlobalState("State = 42)") == 42)
    }

    // MARK: - trimFirewallAppOutput

    @Test
    func trimFirewallAppOutputTrims() {
        #expect(DoctorChecks.trimFirewallAppOutput("  hello  ") == "hello")
    }

    @Test
    func trimFirewallAppOutputRemovesNewlines() {
        #expect(DoctorChecks.trimFirewallAppOutput("\n\n/usr/libexec/bootpd is permitted\n") == "/usr/libexec/bootpd is permitted")
    }

    @Test
    func trimFirewallAppOutputEmpty() {
        #expect(DoctorChecks.trimFirewallAppOutput("") == "")
    }

    @Test
    func trimFirewallAppOutputWhitespaceOnly() {
        #expect(DoctorChecks.trimFirewallAppOutput("   \n\t  \n") == "")
    }

    // MARK: - extractBootpdLogLines

    @Test
    func bootpdLogHeaderOnlyYieldsNoLines() {
        // `log show --style compact` always prints this header, even with zero
        // matching entries. It must not be reported as a log line.
        let output = "Timestamp               Ty Process[PID:TID]\n"
        #expect(DoctorChecks.extractBootpdLogLines(output).isEmpty)
    }

    @Test
    func bootpdLogHeaderStrippedRealEntriesKept() {
        let output = """
        Timestamp               Ty Process[PID:TID]
        2026-07-04 13:37:00.123456+0900 I  bootpd[123:456] service enabled
        2026-07-04 13:37:01.234567+0900 I  bootpd[123:456] DHCP OFFER
        """
        let lines = DoctorChecks.extractBootpdLogLines(output)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.contains("bootpd") })
    }

    @Test
    func bootpdLogEmptyOutputYieldsNoLines() {
        #expect(DoctorChecks.extractBootpdLogLines("").isEmpty)
        #expect(DoctorChecks.extractBootpdLogLines("\n\n  \n").isEmpty)
    }

    // MARK: - parseLaunchctlPrint

    @Test
    func launchctlPrintBasic() {
        let out = """
        com.apple.bootpd = {
            active count = 0
            state = not running
            last exit code = 0
        }
        """
        let parsed = DoctorChecks.parseLaunchctlPrint(out)
        #expect(parsed.state == "not running")
        #expect(parsed.lastExitCode == "0")
    }

    @Test
    func launchctlPrintMissing() {
        let parsed = DoctorChecks.parseLaunchctlPrint("unrelated output")
        #expect(parsed.state == nil)
        #expect(parsed.lastExitCode == nil)
    }

    @Test
    func launchctlPrintOnlyState() {
        let out = "    state = running\n"
        let parsed = DoctorChecks.parseLaunchctlPrint(out)
        #expect(parsed.state == "running")
        #expect(parsed.lastExitCode == nil)
    }

    @Test
    func launchctlPrintOnlyExitCode() {
        let out = "    last exit code = 137\n"
        let parsed = DoctorChecks.parseLaunchctlPrint(out)
        #expect(parsed.state == nil)
        #expect(parsed.lastExitCode == "137")
    }

    @Test
    func launchctlPrintLeadingWhitespace() {
        let out = "\t\tstate = idle\n\t\tlast exit code = -15\n"
        let parsed = DoctorChecks.parseLaunchctlPrint(out)
        #expect(parsed.state == "idle")
        #expect(parsed.lastExitCode == "-15")
    }

    @Test
    func launchctlPrintEmpty() {
        let parsed = DoctorChecks.parseLaunchctlPrint("")
        #expect(parsed.state == nil)
        #expect(parsed.lastExitCode == nil)
    }

    // MARK: - classifyLeaseFileSize

    @Test
    func leaseSizeMissing() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: nil, exists: false) == .info)
    }

    @Test
    func leaseSizeExistsButCountNil() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: nil, exists: true) == .info)
    }

    @Test
    func leaseSizeZero() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: 0, exists: true) == .ok)
    }

    @Test
    func leaseSizeSmall() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: 5, exists: true) == .ok)
    }

    @Test
    func leaseSizeAtBoundary() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: 250, exists: true) == .ok)
    }

    @Test
    func leaseSizeJustAboveBoundary() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: 251, exists: true) == .warning)
    }

    @Test
    func leaseSizeLarge() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: 300, exists: true) == .warning)
    }

    @Test
    func leaseSizeInconsistent() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: 5, exists: false) == .info)
    }

    // MARK: - countLeaseEntries

    @Test
    func countLeaseEntriesBasic() {
        let content = """
        {
            name=a
        }
        {
            name=b
        }
        """
        #expect(DoctorChecks.countLeaseEntries(content) == 2)
    }

    @Test
    func countLeaseEntriesEmpty() {
        #expect(DoctorChecks.countLeaseEntries("") == 0)
    }

    @Test
    func countLeaseEntriesNoBraces() {
        #expect(DoctorChecks.countLeaseEntries("no braces here") == 0)
    }

    @Test
    func countLeaseEntriesSingleBlock() {
        let content = """
        {
            name=solo
        }
        """
        #expect(DoctorChecks.countLeaseEntries(content) == 1)
    }

    @Test
    func countLeaseEntriesUnbalanced() {
        #expect(DoctorChecks.countLeaseEntries("}}}") == 3)
    }

    // MARK: - Nix store lock files

    @Test
    func staleNixStoreLockMatches() {
        #expect(DoctorChecks.isPotentialStaleNixStoreLock(
            name: "abc.lock",
            fileType: .typeRegular,
            fileSize: 0,
            permissions: 0o600
        ))
    }

    @Test
    func staleNixStoreLockRejectsNonLockFiles() {
        #expect(!DoctorChecks.isPotentialStaleNixStoreLock(
            name: "abc.tmp",
            fileType: .typeRegular,
            fileSize: 0,
            permissions: 0o600
        ))
    }

    @Test
    func staleNixStoreLockRejectsNonEmptyFiles() {
        #expect(!DoctorChecks.isPotentialStaleNixStoreLock(
            name: "abc.lock",
            fileType: .typeRegular,
            fileSize: 1,
            permissions: 0o600
        ))
    }

    @Test
    func staleNixStoreLockRejectsDifferentPermissions() {
        #expect(!DoctorChecks.isPotentialStaleNixStoreLock(
            name: "abc.lock",
            fileType: .typeRegular,
            fileSize: 0,
            permissions: 0o644
        ))
    }

    @Test
    func staleNixStoreLockRejectsDirectories() {
        #expect(!DoctorChecks.isPotentialStaleNixStoreLock(
            name: "abc.lock",
            fileType: .typeDirectory,
            fileSize: 0,
            permissions: 0o600
        ))
    }

    @Test
    func staleNixStoreLockCountUnavailable() {
        #expect(DoctorChecks.classifyStaleNixStoreLockCount(nil) == .skipped)
    }

    @Test
    func staleNixStoreLockCountZero() {
        #expect(DoctorChecks.classifyStaleNixStoreLockCount(0) == .ok)
    }

    @Test
    func staleNixStoreLockCountPositive() {
        #expect(DoctorChecks.classifyStaleNixStoreLockCount(1) == .warning)
    }

    // MARK: - marker

    @Test
    func markerValues() {
        #expect(DoctorChecks.marker(for: .ok) == "[ OK ]")
        #expect(DoctorChecks.marker(for: .warning) == "[WARN]")
        #expect(DoctorChecks.marker(for: .info) == "[INFO]")
        #expect(DoctorChecks.marker(for: .skipped) == "[SKIP]")
    }

    // MARK: - renderReport

    @Test
    func renderReportBasic() {
        let results = [
            DoctorCheckResult(label: "Label A", status: .ok, detail: ["line 1", "line 2"]),
            DoctorCheckResult(label: "Label B", status: .warning, detail: ["oops"]),
        ]
        let rendered = DoctorChecks.renderReport(results)
        #expect(rendered.contains("[ OK ] Label A"))
        #expect(rendered.contains("[WARN] Label B"))
        #expect(rendered.contains("line 1"))
        #expect(rendered.contains("oops"))
    }

    @Test
    func renderReportEmpty() {
        #expect(DoctorChecks.renderReport([]) == "")
    }

    @Test
    func renderReportNoDetail() {
        let rendered = DoctorChecks.renderReport([
            DoctorCheckResult(label: "Bare", status: .info, detail: []),
        ])
        #expect(rendered == "[INFO] Bare")
    }

    @Test
    func renderReportOrdering() {
        let rendered = DoctorChecks.renderReport([
            DoctorCheckResult(label: "First", status: .ok, detail: []),
            DoctorCheckResult(label: "Second", status: .warning, detail: []),
            DoctorCheckResult(label: "Third", status: .skipped, detail: []),
        ])
        let firstIdx = rendered.range(of: "First")?.lowerBound
        let secondIdx = rendered.range(of: "Second")?.lowerBound
        let thirdIdx = rendered.range(of: "Third")?.lowerBound
        #expect(firstIdx != nil && secondIdx != nil && thirdIdx != nil)
        if let a = firstIdx, let b = secondIdx, let c = thirdIdx {
            #expect(a < b)
            #expect(b < c)
        }
    }

    @Test
    func renderReportIndentation() {
        let rendered = DoctorChecks.renderReport([
            DoctorCheckResult(label: "L", status: .ok, detail: ["d1"]),
        ])
        #expect(rendered.contains("\n       d1"))
    }
}
