import Foundation

/// Diagnostic output status for a single check.
enum DoctorStatus: String, Codable {
    case ok
    case warning
    case info
    case skipped
}

/// Result of one diagnostic check: label + status + detail lines.
struct DoctorCheckResult: Codable {
    let label: String
    let status: DoctorStatus
    let detail: [String]
}

/// Machine-readable diagnostic report emitted by `doctor --json`.
struct DoctorReport: Codable {
    let version: String
    let overall: DoctorStatus
    let checks: [DoctorCheckResult]
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
            // whitespacesAndNewlines (not whitespaces) so a trailing \r on CRLF
            // input doesn't leak into the parsed state/exit-code values.
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: - Nix store lock files

    /// Match the old self-healing lock-file heuristic without mutating the store.
    static func isPotentialStaleNixStoreLock(name: String, fileType: FileAttributeType, fileSize: UInt64, permissions: Int) -> Bool {
        name.hasSuffix(".lock") &&
            fileType == .typeRegular &&
            fileSize == 0 &&
            permissions == 0o600
    }

    static func classifyStaleNixStoreLockCount(_ count: Int?) -> DoctorStatus {
        guard let count else { return .skipped }
        if count > 0 { return .warning }
        return .ok
    }

    // MARK: - bootpd log filtering

    /// Extract meaningful log lines from `log show --style compact` output.
    ///
    /// The compact style ALWAYS emits a column header
    /// ("Timestamp               Ty Process[PID:TID]") — even when zero entries
    /// match the predicate. Without dropping it, the doctor reports that header as
    /// if it were a real bootpd log line and the "No bootpd log entries" message
    /// becomes unreachable. Real entries start with an ISO timestamp, never the
    /// literal word "Timestamp", so this filter is precise.
    static func extractBootpdLogLines(_ output: String) -> [String] {
        output
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return false }
                if trimmed.hasPrefix("Timestamp"), trimmed.contains("Process[PID:TID]") { return false }
                return true
            }
    }

    // MARK: - Report formatting

    /// Worst-case status across all checks (warning dominates), for a single
    /// machine-readable verdict. Info/skipped are not failures.
    static func overallStatus(_ results: [DoctorCheckResult]) -> DoctorStatus {
        results.contains { $0.status == .warning } ? .warning : .ok
    }

    /// Render a status marker for a check line. Plain ASCII; no emoji.
    static func marker(for status: DoctorStatus) -> String {
        switch status {
        case .ok: "[ OK ]"
        case .warning: "[WARN]"
        case .info: "[INFO]"
        case .skipped: "[SKIP]"
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
