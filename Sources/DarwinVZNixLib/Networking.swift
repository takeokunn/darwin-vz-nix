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

    /// Discover guest VM IP by polling /var/db/dhcpd_leases for the guest hostname.
    /// macOS's vmnet DHCP server writes lease entries with the hostname reported by the guest.
    func discoverGuestIP(hostname: String = Constants.guestHostname, timeout: TimeInterval = 120, notBefore: Date) async throws -> String {
        let leaseFile = "/var/db/dhcpd_leases"
        let deadline = Date().addingTimeInterval(timeout)
        let notBeforeTimestamp = UInt64(notBefore.timeIntervalSince1970)

        while Date() < deadline {
            if let ip = parseLeaseFile(path: leaseFile, hostname: hostname, notBefore: notBeforeTimestamp) {
                return ip
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
    }

    // MARK: - SSH Connection

    func connectSSH(extraArgs: [String] = []) throws {
        guard FileManager.default.fileExists(atPath: sshKeyPath.path) else {
            throw NetworkError.sshKeyNotFound(sshKeyPath.path)
        }

        let guestIP = try readGuestIP()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-i", sshKeyPath.path,
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(stateDirectory.appendingPathComponent("ssh/known_hosts").path)",
            "-o", "LogLevel=ERROR",
            "builder@\(guestIP)",
        ] + extraArgs
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        let status = process.terminationStatus
        if status != 0 {
            throw NetworkError.sshConnectionFailed(status)
        }
    }
}
