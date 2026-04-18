import Foundation

/// Diagnostic output status for a single check.
enum DoctorStatus {
    case ok
    case warning
    case info
    case skipped
}

/// Result of one diagnostic check: label + status + detail lines.
struct DoctorCheckResult {
    let label: String
    let status: DoctorStatus
    let detail: [String]
}

enum DoctorChecks {
    // MARK: - Firewall global state

    /// Parse `socketfilterfw --getglobalstate` output.
    /// Expected shapes:
    ///   "Firewall is disabled. (State = 0)"
    ///   "Firewall is enabled. (State = 1)"
    ///   "Firewall is on for specific services. (State = 2)"
    /// Returns the raw state number, or nil if not parseable.
    static func parseFirewallGlobalState(_ output: String) -> Int? {
        guard let stateRange = output.range(of: "State = ") else { return nil }
        let after = output[stateRange.upperBound...]
        let digits = after.prefix { $0.isNumber }
        return Int(digits)
    }

    // MARK: - Firewall bootpd app state

    /// Parse `socketfilterfw --getappblocked /usr/libexec/bootpd` raw output.
    /// Returns the output trimmed to a single line for display. This check is
    /// INFORMATIONAL ONLY because upstream (minikube#19680, minikube#20399)
    /// documents that the string output is not a reliable pass/fail signal.
    static func trimFirewallAppOutput(_ output: String) -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - launchctl print

    /// Parse `launchctl print system/com.apple.bootpd` output for state + last exit code.
    /// Missing service (exit != 0 from launchctl) is reported by the caller — this
    /// function assumes the raw stdout is present.
    static func parseLaunchctlPrint(_ output: String) -> (state: String?, lastExitCode: String?) {
        var state: String?
        var lastExitCode: String?
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("state = ") {
                state = String(trimmed.dropFirst("state = ".count))
            } else if trimmed.hasPrefix("last exit code = ") {
                lastExitCode = String(trimmed.dropFirst("last exit code = ".count))
            }
        }
        return (state, lastExitCode)
    }

    // MARK: - dhcpd_leases size

    /// Classify lease-file size. INFO if missing (expected on fresh macOS before
    /// any VM has run). WARNING only when entries exceed a heuristic threshold
    /// that suggests subnet exhaustion.
    static func classifyLeaseFileSize(entryCount: Int?, exists: Bool) -> DoctorStatus {
        guard exists else { return .info }
        guard let count = entryCount else { return .info }
        if count > 250 { return .warning }
        return .ok
    }

    /// Count top-level `{ ... }` blocks in a dhcpd_leases file.
    static func countLeaseEntries(_ content: String) -> Int {
        content.components(separatedBy: "}").count - 1
    }

    // MARK: - Report formatting

    /// Render a status marker for a check line. Plain ASCII; no emoji.
    static func marker(for status: DoctorStatus) -> String {
        switch status {
        case .ok: return "[ OK ]"
        case .warning: return "[WARN]"
        case .info: return "[INFO]"
        case .skipped: return "[SKIP]"
        }
    }

    /// Render a full report to a string. Each check: "[STATUS] label" + indented detail lines.
    static func renderReport(_ results: [DoctorCheckResult]) -> String {
        var lines: [String] = []
        for r in results {
            lines.append("\(marker(for: r.status)) \(r.label)")
            for d in r.detail {
                lines.append("       \(d)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
