import Foundation

enum NetworkError: LocalizedError {
    case sshKeyGenerationFailed(Int32)
    case sshConnectionFailed(Int32)
    case sshKeyNotFound(String)
    case guestIPNotFound

    var errorDescription: String? {
        switch self {
        case let .sshKeyGenerationFailed(status):
            "SSH key generation failed with exit code: \(status)"
        case let .sshConnectionFailed(status):
            "SSH connection failed with exit code: \(status)"
        case let .sshKeyNotFound(path):
            "SSH key not found at: \(path)"
        case .guestIPNotFound:
            """
            Could not discover guest VM IP address after polling DHCP leases and the ARP table.
            Likely causes on the macOS host:
              1. bootpd (the DHCP server behind vmnet) did not answer DHCPDISCOVER — try: sudo killall bootpd
              2. Application Firewall is blocking /usr/libexec/bootpd
              3. The VM finished booting but its network interface is not up yet
            Run `darwin-vz-nix doctor` for host-side diagnostics.
            """
        }
    }
}

struct NetworkManager {
    let stateDirectory: URL

    var sshKeyPath: URL {
        VMConfig.sshKeyURL(for: stateDirectory)
    }

    /// Deterministic per-state-directory MAC, matching the one assigned to the
    /// VM's network device. Discovery keys on this so two VMs never cross-match.
    var macAddress: String {
        VMConfig.macAddress(for: stateDirectory)
    }

    /// True iff `string` is a well-formed IPv4 dotted-quad. Used to reject
    /// garbage from lease/ARP parsing before it becomes an SSH target.
    static func isValidIPv4(_ string: String) -> Bool {
        var addr = in_addr()
        return string.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    /// Best-effort TCP liveness probe used to validate an ARP-swept candidate
    /// before trusting it: a stale ARP entry from a prior boot won't answer.
    static func isTCPPortOpen(ip: String, port: Int, timeoutSeconds: Int = 1) -> Bool {
        guard isValidIPv4(ip) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-z", "-G", String(timeoutSeconds), "-w", String(timeoutSeconds), ip, String(port)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0
    }

    func ensureSSHKeys() throws {
        let sshDir = VMConfig.sshDirectory(for: stateDirectory)
        let publicKeyPath = URL(fileURLWithPath: sshKeyPath.path + ".pub")
        let fm = FileManager.default

        try fm.createDirectory(
            at: sshDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir.path)

        let hasPrivateKey = fm.fileExists(atPath: sshKeyPath.path)
        let hasPublicKey = fm.fileExists(atPath: publicKeyPath.path)

        if hasPrivateKey, hasPublicKey {
            try setSSHKeyPermissions(publicKeyPath: publicKeyPath)
            return
        }

        if hasPrivateKey {
            do {
                let publicKey = try derivePublicKey()
                try "\(publicKey) builder@darwin-vz-nix\n".write(to: publicKeyPath, atomically: true, encoding: .utf8)
                try setSSHKeyPermissions(publicKeyPath: publicKeyPath)
                return
            } catch {
                try? fm.removeItem(at: sshKeyPath)
                try? fm.removeItem(at: publicKeyPath)
            }
        } else if hasPublicKey {
            try? fm.removeItem(at: publicKeyPath)
        }

        try generateSSHKeyPair()
        try setSSHKeyPermissions(publicKeyPath: publicKeyPath)
    }

    private func generateSSHKeyPair() throws {
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

    private func derivePublicKey() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-y", "-f", sshKeyPath.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        // Drain the pipe BEFORE waiting: waitUntilExit() with an unread pipe
        // deadlocks once the child's output exceeds the 64 KB pipe buffer
        // (child blocks in write(), parent blocks in wait).
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NetworkError.sshKeyGenerationFailed(process.terminationStatus)
        }

        let publicKey = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !publicKey.isEmpty else {
            throw NetworkError.sshKeyGenerationFailed(process.terminationStatus)
        }
        return publicKey
    }

    private func setSSHKeyPermissions(publicKeyPath: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sshKeyPath.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: publicKeyPath.path)
    }

    // MARK: - Guest IP Discovery

    /// Discover guest VM IP by polling /var/db/dhcpd_leases for the guest hostname,
    /// then verifying the candidate IP via ARP table MAC address check.
    /// macOS's vmnet DHCP server writes lease entries with the hostname reported by the guest.
    func discoverGuestIP(hostname: String = Constants.guestHostname, timeout: TimeInterval = 120, notBefore: Date) async throws -> String {
        let leaseFile = "/var/db/dhcpd_leases"
        let deadline = Date().addingTimeInterval(timeout)
        let notBeforeTimestamp = UInt64(notBefore.timeIntervalSince1970)
        let mac = macAddress

        var consecutiveLeaseMisses = 0
        var pollMilliseconds = 500

        while Date() < deadline {
            // Primary path: DHCP lease bound to our hostname, cross-checked against
            // our per-instance MAC. Preferred whenever bootpd answered.
            if let ip = parseLeaseFile(path: leaseFile, hostname: hostname, notBefore: notBeforeTimestamp),
               Self.isValidIPv4(ip),
               Self.verifyIPViaARP(ip: ip, expectedMAC: mac)
            {
                return ip
            }

            consecutiveLeaseMisses += 1

            // Fallback: ARP sweep by our MAC. Recovers when bootpd never wrote a
            // lease (firewall / stuck launchd) but the guest still reached the host
            // via ARP. Gated behind several lease misses AND a TCP/22 liveness probe
            // so a *stale* ARP entry from a prior boot can't yield a dead/wrong IP.
            if consecutiveLeaseMisses >= 3,
               let ip = Self.scanARPTableForMAC(mac),
               Self.isValidIPv4(ip),
               Self.isTCPPortOpen(ip: ip, port: 22)
            {
                return ip
            }

            try await Task.sleep(for: .milliseconds(pollMilliseconds))
            // Linear backoff (cap 2s) to avoid spawning ~240 arp/nc subprocesses.
            pollMilliseconds = min(pollMilliseconds + 250, 2000)
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
                // Trim newlines too, not just spaces: a CRLF-terminated lease file
                // would otherwise leave a trailing \r on every value (\r is absent
                // from CharacterSet.whitespaces), breaking the exact `name==hostname`
                // match and poisoning the parsed ip_address.
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
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
        process.arguments = ["-n", ip]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }
        // Drain the pipe BEFORE waiting (see derivePublicKey for the deadlock rationale).
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        // ARP output format: "? (192.168.64.8) at 2:da:72:56:0:1 on bridge100 ..."
        // "(incomplete)" means no ARP response — the host is unreachable.
        guard let atRange = output.range(of: " at "),
              let onRange = output.range(of: " on ", range: atRange.upperBound ..< output.endIndex)
        else {
            return false
        }
        let arpMAC = String(output[atRange.upperBound ..< onRange.lowerBound])
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

    // MARK: - ARP Table Sweep (fallback when DHCP lease is missing)

    /// Parse `arp -an` output and return the first IP whose MAC matches `expectedMAC`.
    /// Used when the DHCP lease file has no entry for our guest (e.g. bootpd did not
    /// answer DHCPDISCOVER but the guest still reached the host via ARP).
    /// Separated from I/O to enable unit testing.
    static func scanARPTableForMAC(_ arpOutput: String, expectedMAC: String) -> String? {
        let target = normalizeMAC(expectedMAC)
        for line in arpOutput.components(separatedBy: "\n") {
            // Format: "? (192.168.64.8) at 2:da:72:56:0:1 on bridge100 ifscope [ethernet]"
            guard let openParen = line.firstIndex(of: "("),
                  let closeParen = line.firstIndex(of: ")"),
                  openParen < closeParen,
                  let atRange = line.range(of: " at ", range: closeParen ..< line.endIndex),
                  let onRange = line.range(of: " on ", range: atRange.upperBound ..< line.endIndex)
            else {
                continue
            }
            let ip = String(line[line.index(after: openParen) ..< closeParen])
            let mac = String(line[atRange.upperBound ..< onRange.lowerBound])
            if mac == "(incomplete)" {
                continue
            }
            if normalizeMAC(mac) == target {
                return ip
            }
        }
        return nil
    }

    /// Shell out to `arp -an` and search the table for our MAC.
    /// Returns nil on process failure or no match.
    static func scanARPTableForMAC(_ expectedMAC: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-an"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain the pipe BEFORE waiting: `arp -an` output scales with the ARP
        // table and can exceed the 64 KB pipe buffer on a busy network, which
        // would deadlock IP discovery (see derivePublicKey).
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return scanARPTableForMAC(output, expectedMAC: expectedMAC)
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
        guard NetworkManager.isValidIPv4(ip) else {
            throw NetworkError.guestIPNotFound
        }
        return ip
    }

    /// Save guest IP to the state directory.
    func writeGuestIP(_ ip: String) throws {
        guard NetworkManager.isValidIPv4(ip) else {
            throw NetworkError.guestIPNotFound
        }
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let guestIPFileURL = VMConfig.guestIPFileURL(for: stateDirectory)
        try ip.write(to: guestIPFileURL, atomically: true, encoding: .utf8)
        // 0o644: the darwin-module ProxyCommand (`ssh darwin-vz-nix`) reads this
        // file as whichever unprivileged user runs ssh, not as the root/launchd
        // daemon that writes it. It only ever holds a validated IPv4 string, so
        // world-readable is safe — unlike the SSH private key, which stays 0600.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: guestIPFileURL.path
        )
    }

    // MARK: - SSH Connection

    /// Remove any known_hosts entry keyed by `host` (an IP address or a literal
    /// ssh_config `Host` alias). Best-effort: a missing file or ssh-keygen
    /// failure is non-fatal.
    static func removeKnownHostEntry(host: String, knownHostsURL: URL) {
        // Refuse to operate on a symlink. `scrubUserKnownHosts` runs this as the
        // root/launchd daemon against a file inside an unprivileged user's
        // `~/.ssh`; `ssh-keygen -R` follows symlinks, so a link swapped in for
        // the file would make root rewrite whatever it points at (e.g.
        // /etc/sudoers). Open O_NOFOLLOW — which fails with ELOOP on a symlink —
        // and require a regular file. A missing file is silently skipped.
        let fd = open(knownHostsURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        var st = stat()
        let isRegularFile = fstat(fd, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
        close(fd)
        guard isRegularFile else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-R", host, "-f", knownHostsURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Only wait if the launch succeeded: waitUntilExit() on a process that
        // never launched is undefined (NSTask may raise).
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    /// Remove any stale host-key entry for `ip` from the known_hosts file so a
    /// rebuilt guest reusing the same NAT IP doesn't hard-fail host-key checking.
    static func scrubKnownHost(ip: String, knownHostsURL: URL) {
        guard isValidIPv4(ip) else {
            return
        }
        removeKnownHostEntry(host: ip, knownHostsURL: knownHostsURL)
    }

    /// The `Host` alias `nix/host/darwin-module.nix`'s `ssh_config.d` entry
    /// registers for the guest.
    private static let sshAlias = "darwin-vz-nix"

    /// Evict stale `darwin-vz-nix_known_hosts` entries for both the current
    /// process's own user and the logged-in macOS console user.
    ///
    /// The darwin-module points plain `ssh darwin-vz-nix` (interactive users)
    /// and `nix.buildMachines` (root's nix-daemon, for distributed builds) at
    /// `~/.ssh/darwin-vz-nix_known_hosts`, connecting via the `Host
    /// darwin-vz-nix` alias through a `ProxyCommand` — so ssh has no
    /// hostname/IP of its own to resolve and records the entry under the
    /// literal alias name, not the guest IP. `scrubKnownHost(ip:)` above (used
    /// by `start` to evict the state-directory pin for the freshly discovered
    /// IP) can't evict that: it validates its argument as an IPv4 address and
    /// would reject the alias outright. Without this, a guest whose host key
    /// changes hard-fails every SSH path outside the `ssh` subcommand.
    ///
    /// Because `start` runs as the root/launchd daemon, scrubbing the console
    /// user's file leaves both the rewritten known_hosts and the `.old` backup
    /// `ssh-keygen -R` drops root-owned — which breaks the user's plain `ssh
    /// darwin-vz-nix` (it can no longer append the new host key). So the
    /// console-user branch chowns the file back to that user and deletes the
    /// root-owned `.old` sibling afterward.
    /// Best-effort: a failed lookup or missing file is silently skipped.
    static func scrubUserKnownHosts() {
        let knownHostsSuffix = ".ssh/darwin-vz-nix_known_hosts"

        removeKnownHostEntry(
            host: sshAlias,
            knownHostsURL: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(knownHostsSuffix)
        )

        let consoleUserProcess = Process()
        consoleUserProcess.executableURL = URL(fileURLWithPath: "/usr/bin/stat")
        consoleUserProcess.arguments = ["-f", "%Su", "/dev/console"]
        let stdoutPipe = Pipe()
        consoleUserProcess.standardOutput = stdoutPipe
        consoleUserProcess.standardError = FileHandle.nullDevice
        guard (try? consoleUserProcess.run()) != nil else { return }
        // Drain the pipe BEFORE waiting (see derivePublicKey for the deadlock rationale).
        let consoleUserData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        consoleUserProcess.waitUntilExit()

        guard
            let consoleUser = String(
                data: consoleUserData,
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines),
            !consoleUser.isEmpty,
            let consoleHome = NSHomeDirectoryForUser(consoleUser)
        else {
            return
        }

        let consoleKnownHostsURL = URL(fileURLWithPath: consoleHome).appendingPathComponent(knownHostsSuffix)
        removeKnownHostEntry(host: sshAlias, knownHostsURL: consoleKnownHostsURL)
        restoreConsoleUserOwnership(of: consoleKnownHostsURL, to: consoleUser)
    }

    /// Restore ownership of a foreign (console-user) known_hosts file to
    /// `consoleUser` after a root scrub, and delete the root-owned `.old`
    /// backup `ssh-keygen -R` leaves behind. Without this the user's plain
    /// `ssh darwin-vz-nix` can't append the new host key (the file flips to
    /// root:wheel 0600). Best-effort: any failure must not crash `start`.
    private static func restoreConsoleUserOwnership(of knownHostsURL: URL, to consoleUser: String) {
        // ssh-keygen -R rewrites in place and leaves a "<file>.old" backup; both
        // become root-owned when the scrub runs as the daemon. Drop the backup
        // so it can't linger root-owned.
        let backupURL = URL(fileURLWithPath: knownHostsURL.path + ".old")
        try? FileManager.default.removeItem(at: backupURL)

        // chown WITHOUT following symlinks. `setAttributes(ofItemAtPath:)` uses
        // path-based chown(), which follows a symlink — so a link swapped into
        // the user-owned `~/.ssh` between check and chown would redirect the
        // root chown onto an arbitrary file (e.g. /etc/sudoers), handing the
        // user ownership of it: a local privilege-escalation primitive. Instead
        // open the path O_NOFOLLOW (fails with ELOOP on a symlink), confirm a
        // regular file, and fchown the descriptor — which cannot be re-pointed
        // by a later symlink swap.
        guard let pw = getpwnam(consoleUser) else { return }
        let fd = open(knownHostsURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return }
        _ = fchown(fd, pw.pointee.pw_uid, pw.pointee.pw_gid)
    }

    /// The known_hosts file the `darwin-vz-nix ssh` subcommand pins guest host
    /// keys into. Scrubbed once per VM boot (see `scrubStateKnownHosts`), NOT
    /// per connection — per-connection scrubbing would delete the pin right
    /// before every handshake and reduce `accept-new` to "accept anything",
    /// giving an on-segment MITM a fresh first-connection window every time.
    func stateKnownHostsURL() -> URL {
        stateDirectory.appendingPathComponent("ssh/known_hosts")
    }

    /// Evict the state-directory known_hosts entry for `ip`. Called by `start`
    /// right after IP discovery: a recreated guest disk (new host key) or a NAT
    /// IP handed to a different VM would otherwise hard-fail every later `ssh`
    /// with "REMOTE HOST IDENTIFICATION HAS CHANGED". Connections within one
    /// boot then keep full host-key verification against the re-pinned key.
    func scrubStateKnownHosts(ip: String) {
        Self.scrubKnownHost(ip: ip, knownHostsURL: stateKnownHostsURL())
    }

    func connectSSH(extraArgs: [String] = []) throws {
        guard FileManager.default.fileExists(atPath: sshKeyPath.path) else {
            throw NetworkError.sshKeyNotFound(sshKeyPath.path)
        }

        let guestIP = try readGuestIP()
        let knownHostsURL = stateKnownHostsURL()

        var arguments = [
            "/usr/bin/ssh",
            "-i", sshKeyPath.path,
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsURL.path)",
            "-o", "LogLevel=ERROR",
        ]

        // Allocate a PTY when running a remote command interactively.
        // SSH allocates a PTY by default for interactive sessions (no command),
        // but not when a command is specified. Programs like top, htop, vim
        // require a PTY to function correctly.
        if !extraArgs.isEmpty, isatty(STDIN_FILENO) != 0 {
            arguments.append("-t")
        }

        arguments.append("builder@\(guestIP)")
        arguments += extraArgs

        // Use execv to replace the current process with ssh.
        // Process() doesn't transfer terminal control to the child,
        // which prevents the login shell from starting interactively.
        let cArgs = arguments.map { strdup($0) } + [nil]
        execv("/usr/bin/ssh", cArgs)

        // execv only returns on failure
        throw NetworkError.sshConnectionFailed(errno)
    }
}
