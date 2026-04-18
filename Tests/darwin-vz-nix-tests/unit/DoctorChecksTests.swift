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

    // MARK: - classifyLeaseFileSize

    @Test("classifyLeaseFileSize returns info when file missing")
    func leaseSizeMissing() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: nil, exists: false) == .info)
    }

    @Test("classifyLeaseFileSize returns ok for small counts")
    func leaseSizeSmall() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: 5, exists: true) == .ok)
    }

    @Test("classifyLeaseFileSize returns warning when exceeding threshold")
    func leaseSizeLarge() {
        #expect(DoctorChecks.classifyLeaseFileSize(entryCount: 300, exists: true) == .warning)
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

    @Test("marker returns expected strings")
    func markerValues() {
        #expect(DoctorChecks.marker(for: .ok) == "[ OK ]")
        #expect(DoctorChecks.marker(for: .warning) == "[WARN]")
        #expect(DoctorChecks.marker(for: .info) == "[INFO]")
        #expect(DoctorChecks.marker(for: .skipped) == "[SKIP]")
    }
}
