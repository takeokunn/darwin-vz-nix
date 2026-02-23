import Foundation

enum NetworkError: LocalizedError {
    case sshKeyGenerationFailed(Int32)
    case sshConnectionFailed(Int32)
    case sshKeyNotFound(String)
    case guestIPNotFound

    var errorDescription: String? {
        switch self {
        case let .sshKeyGenerationFailed(status):
            return "SSH key generation failed with exit code: \(status)"
        case let .sshConnectionFailed(status):
            return "SSH connection failed with exit code: \(status)"
        case let .sshKeyNotFound(path):
            return "SSH key not found at: \(path)"
        case .guestIPNotFound:
            return "Could not discover guest VM IP address. Is the VM running?"
        }
    }
}

struct NetworkManager {
    let stateDirectory: URL

    var sshKeyPath: URL {
        VMConfig.sshKeyURL(for: stateDirectory)
    }

    func ensureSSHKeys() throws {
        let sshDir = VMConfig.sshDirectory(for: stateDirectory)

        try FileManager.default.createDirectory(
            at: sshDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if FileManager.default.fileExists(atPath: sshKeyPath.path) {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = [
            "-q",
            "-f", sshKeyPath.path,
            "-t", "ed25519",
            "-N", "",
            "-C", "builder@darwin-vz-nix",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NetworkError.sshKeyGenerationFailed(process.terminationStatus)
        }
    }

    // MARK: - Guest IP Discovery

    /// Discover guest VM IP by polling /var/db/dhcpd_leases for the guest hostname,
    /// then verifying the candidate IP via ARP table MAC address check.
    /// macOS's vmnet DHCP server writes lease entries with the hostname reported by the guest.
    func discoverGuestIP(hostname: String = Constants.guestHostname, timeout: TimeInterval = 120, notBefore: Date) async throws -> String {
        let leaseFile = "/var/db/dhcpd_leases"
        let deadline = Date().addingTimeInterval(timeout)
        let notBeforeTimestamp = UInt64(notBefore.timeIntervalSince1970)

        while Date() < deadline {
            if let ip = parseLeaseFile(path: leaseFile, hostname: hostname, notBefore: notBeforeTimestamp) {
                // Verify the candidate IP belongs to our VM by checking MAC in ARP table.
                // Stale DHCP leases from previous boots can match the hostname filter,
                // so we cross-check against the deterministic MAC address.
                if Self.verifyIPViaARP(ip: ip, expectedMAC: Constants.macAddressString) {
                    return ip
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        throw NetworkError.guestIPNotFound
    }

    /// Parse macOS DHCP lease content for a matching hostname.
    /// This is separated from file I/O to enable unit testing.
    static func parseLeaseContent(_ content: String, hostname: String, notBefore: UInt64) -> String? {
        var newestTimestamp: UInt64 = 0
        var newestIP: String?

        let blocks = content.components(separatedBy: "}")
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            var name: String?
            var ipAddress: String?
            var leaseTimestamp: UInt64 = 0

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("name=") {
                    name = String(trimmed.dropFirst("name=".count))
                } else if trimmed.hasPrefix("ip_address=") {
                    ipAddress = String(trimmed.dropFirst("ip_address=".count))
                } else if trimmed.hasPrefix("lease=0x") {
                    let hexStr = String(trimmed.dropFirst("lease=0x".count))
                    leaseTimestamp = UInt64(hexStr, radix: 16) ?? 0
                }
            }

            if name == hostname, let ip = ipAddress, leaseTimestamp > notBefore, leaseTimestamp >= newestTimestamp {
                newestTimestamp = leaseTimestamp
                newestIP = ip
            }
        }

        return newestIP
    }

    // MARK: - ARP Verification

    /// Verify an IP address belongs to the expected MAC by checking the ARP table.
    /// Returns true if the ARP entry exists and the MAC matches.
    static func verifyIPViaARP(ip: String, expectedMAC: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-an", ip]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // ARP output format: "? (192.168.64.8) at 2:da:72:56:0:1 on bridge100 ..."
        // "(incomplete)" means no ARP response — the host is unreachable.
        guard let atRange = output.range(of: " at "),
              let onRange = output.range(of: " on ", range: atRange.upperBound..<output.endIndex)
        else {
            return false
        }
        let arpMAC = String(output[atRange.upperBound..<onRange.lowerBound])
        if arpMAC == "(incomplete)" {
            return false
        }
        return normalizeMAC(arpMAC) == normalizeMAC(expectedMAC)
    }

    /// Normalize a MAC address for comparison by removing leading zeros from each octet.
    /// e.g. "02:da:72:56:00:01" → "2:da:72:56:0:1"
    static func normalizeMAC(_ mac: String) -> String {
        mac.lowercased()
            .split(separator: ":")
            .map { octet in
                let stripped = String(octet.drop(while: { $0 == "0" }))
                return stripped.isEmpty ? "0" : stripped
            }
            .joined(separator: ":")
    }

    private func parseLeaseFile(path: String, hostname: String, notBefore: UInt64) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return NetworkManager.parseLeaseContent(content, hostname: hostname, notBefore: notBefore)
    }

    /// Read previously saved guest IP from the state directory.
    func readGuestIP() throws -> String {
        let guestIPFileURL = VMConfig.guestIPFileURL(for: stateDirectory)
        guard let content = try? String(contentsOf: guestIPFileURL, encoding: .utf8) else {
            throw NetworkError.guestIPNotFound
        }
        let ip = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else {
            throw NetworkError.guestIPNotFound
        }
        return ip
    }

    /// Save guest IP to the state directory.
    func writeGuestIP(_ ip: String) throws {
        let guestIPFileURL = VMConfig.guestIPFileURL(for: stateDirectory)
        try ip.write(to: guestIPFileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: guestIPFileURL.path
        )
    }

    // MARK: - SSH Connection

    func connectSSH(extraArgs: [String] = []) throws {
        guard FileManager.default.fileExists(atPath: sshKeyPath.path) else {
            throw NetworkError.sshKeyNotFound(sshKeyPath.path)
        }

        let guestIP = try readGuestIP()

        let arguments = [
            "/usr/bin/ssh",
            "-i", sshKeyPath.path,
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(stateDirectory.appendingPathComponent("ssh/known_hosts").path)",
            "-o", "LogLevel=ERROR",
            "builder@\(guestIP)",
        ] + extraArgs

        // Use execv to replace the current process with ssh.
        // Process() doesn't transfer terminal control to the child,
        // which prevents the login shell from starting interactively.
        let cArgs = arguments.map { strdup($0) } + [nil]
        execv("/usr/bin/ssh", cArgs)

        // execv only returns on failure
        throw NetworkError.sshConnectionFailed(errno)
    }
}
