@testable import DarwinVZNixLib
import Testing

@Suite("DoctorChecks", .tags(.unit))
struct DoctorChecksTests {
    // MARK: - parseFirewallGlobalState

    @Test("parseFirewallGlobalState extracts state 0 from disabled output")
    func firewallStateDisabled() {
        let out = "Firewall is disabled. (State = 0)"
        #expect(DoctorChecks.parseFirewallGlobalState(out) == 0)
    }

    @Test("parseFirewallGlobalState extracts state 1 from enabled output")
    func firewallStateEnabled() {
        let out = "Firewall is enabled. (State = 1)"
        #expect(DoctorChecks.parseFirewallGlobalState(out) == 1)
    }

    @Test("parseFirewallGlobalState extracts state 2 from per-service output")
    func firewallStateSpecificServices() {
        let out = "Firewall is on for specific services. (State = 2)"
        #expect(DoctorChecks.parseFirewallGlobalState(out) == 2)
    }

    @Test("parseFirewallGlobalState returns nil for unparseable output")
    func firewallStateUnparseable() {
        #expect(DoctorChecks.parseFirewallGlobalState("unexpected format") == nil)
    }

    @Test("parseFirewallGlobalState returns nil for empty output")
    func firewallStateEmpty() {
        #expect(DoctorChecks.parseFirewallGlobalState("") == nil)
    }

    @Test("parseFirewallGlobalState returns nil when 'State = ' has no trailing digit")
    func firewallStateNoDigit() {
        #expect(DoctorChecks.parseFirewallGlobalState("State = abc") == nil)
    }

    @Test("parseFirewallGlobalState handles multi-digit state numbers")
    func firewallStateMultiDigit() {
        #expect(DoctorChecks.parseFirewallGlobalState("State = 42)") == 42)
    }

    // MARK: - trimFirewallAppOutput

    @Test("trimFirewallAppOutput removes leading and trailing whitespace")
    func trimFirewallAppOutputTrims() {
        #expect(DoctorChecks.trimFirewallAppOutput("  hello  ") == "hello")
    }

    @Test("trimFirewallAppOutput removes leading and trailing newlines")
    func trimFirewallAppOutputRemovesNewlines() {
        #expect(DoctorChecks.trimFirewallAppOutput("\n\n/usr/libexec/bootpd is permitted\n") == "/usr/libexec/bootpd is permitted")
    }

    @Test("trimFirewallAppOutput on empty input returns empty string")
    func trimFirewallAppOutputEmpty() {
        #expect(DoctorChecks.trimFirewallAppOutput("") == "")
    }

    @Test("trimFirewallAppOutput on pure-whitespace input returns empty string")
    func trimFirewallAppOutputWhitespaceOnly() {
        #expect(DoctorChecks.trimFirewallAppOutput("   \n\t  \n") == "")
    }

    // MARK: - parseLaunchctlPrint

    @Test("parseLaunchctlPrint extracts state and last exit code")
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

    @Test("parseLaunchctlPrint handles missing fields")
    func launchctlPrintMissing() {
        let parsed = DoctorChecks.parseLaunchctlPrint("unrelated output")
        #expect(parsed.state == nil)
        #expect(parsed.lastExitCode == nil)
    }

    @Test("parseLaunchctlPrint extracts only state when exit code absent")
    func launchctlPrintOnlyState() {
        let out = "    state = running\n"
        let parsed = DoctorChecks.parseLaunchctlPrint(out)
        #expect(parsed.state == "running")
        #expect(parsed.lastExitCode == nil)
    }

    @Test("parseLaunchctlPrint extracts only lastExitCode when state absent")
    func launchctlPrintOnlyExitCode() {
        let out = "    last exit code = 137\n"
        let parsed = DoctorChecks.parseLaunchctlPrint(out)
        #expect(parsed.state == nil)
        #expect(parsed.lastExitCode == "137")
    }

    @Test("parseLaunchctlPrint trims leading whitespace on each line before matching")
    func launchctlPrintLeadingWhitespace() {
        let out = "\t\tstate = idle\n\t\tlast exit code = -15\n"
        let parsed = DoctorChecks.parseLaunchctlPrint(out)
        #expect(parsed.state == "idle")
        #expect(parsed.lastExitCode == "-15")
    }

    @Test("parseLaunchctlPrint on empty input returns both nil")
    func launchctlPrintEmpty() {
        let parsed = DoctorChecks.parseLaunchctlPrint("")
        #expect(parsed.state == nil)
        #expect(parsed.lastExitCode == nil)
    }

    // MARK: - classifyLeaseFileSize

    @Test("classifyLeaseFileSize returns info when file missing")
    func leaseSizeMissing() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: nil, exists: false) == .info)
    }

    @Test("classifyLeaseFileSize returns info when file present but entryCount is nil")
    func leaseSizeExistsButCountNil() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: nil, exists: true) == .info)
    }

    @Test("classifyLeaseFileSize returns ok for zero entries")
    func leaseSizeZero() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: 0, exists: true) == .ok)
    }

    @Test("classifyLeaseFileSize returns ok for small counts")
    func leaseSizeSmall() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: 5, exists: true) == .ok)
    }

    @Test("classifyLeaseFileSize returns ok at threshold boundary (250)")
    func leaseSizeAtBoundary() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: 250, exists: true) == .ok)
    }

    @Test("classifyLeaseFileSize returns warning just above boundary (251)")
    func leaseSizeJustAboveBoundary() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: 251, exists: true) == .warning)
    }

    @Test("classifyLeaseFileSize returns warning when exceeding threshold")
    func leaseSizeLarge() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: 300, exists: true) == .warning)
    }

    @Test("classifyLeaseFileSize returns info when file missing even if entryCount provided")
    func leaseSizeInconsistent() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: 5, exists: false) == .info)
    }

    // MARK: - countLeaseEntries

    @Test("countLeaseEntries counts closing braces")
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

    @Test("countLeaseEntries returns 0 for empty content")
    func countLeaseEntriesEmpty() {
        #expect(DoctorChecks.countLeaseEntries("") == 0)
    }

    @Test("countLeaseEntries returns 0 for content with no braces")
    func countLeaseEntriesNoBraces() {
        #expect(DoctorChecks.countLeaseEntries("no braces here") == 0)
    }

    @Test("countLeaseEntries counts a single block")
    func countLeaseEntriesSingleBlock() {
        let content = """
        {
            name=solo
        }
        """
        #expect(DoctorChecks.countLeaseEntries(content) == 1)
    }

    @Test("countLeaseEntries counts every closing brace, even without opener")
    func countLeaseEntriesUnbalanced() {
        #expect(DoctorChecks.countLeaseEntries("}}}") == 3)
    }

    // MARK: - marker

    @Test("marker returns expected strings")
    func markerValues() {
        #expect(DoctorChecks.marker(for: .ok) == "[ OK ]")
        #expect(DoctorChecks.marker(for: .warning) == "[WARN]")
        #expect(DoctorChecks.marker(for: .info) == "[INFO]")
        #expect(DoctorChecks.marker(for: .skipped) == "[SKIP]")
    }

    // MARK: - renderReport

    @Test("renderReport emits marker + label + indented details")
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

    @Test("renderReport returns empty string for empty input")
    func renderReportEmpty() {
        #expect(DoctorChecks.renderReport([]) == "")
    }

    @Test("renderReport still emits the label line when detail array is empty")
    func renderReportNoDetail() {
        let rendered = DoctorChecks.renderReport([
            DoctorCheckResult(label: "Bare", status: .info, detail: []),
        ])
        #expect(rendered == "[INFO] Bare")
    }

    @Test("renderReport preserves ordering across checks")
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

    @Test("renderReport indents detail lines with exactly 7 spaces")
    func renderReportIndentation() {
        let rendered = DoctorChecks.renderReport([
            DoctorCheckResult(label: "L", status: .ok, detail: ["d1"]),
        ])
        #expect(rendered.contains("\n       d1"))
    }
}
