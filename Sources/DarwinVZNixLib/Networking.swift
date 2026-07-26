import Foundation

enum NetworkError: LocalizedError {
    case sshKeyGenerationFailed(Int32)
    case sshConnectionFailed(Int32)
    case sshKeyNotFound(String)
    case guestIPNotFound
    case unsafeSSHKeyPath(String)

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
        case let .unsafeSSHKeyPath(path):
            "Refusing to use a symlink or non-regular SSH key file at: \(path)"
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

    func ensureSSHKeys(beforePublicKeyInstall: (() throws -> Void)? = nil) throws {
        let sshDir = VMConfig.sshDirectory(for: stateDirectory)
        let publicKeyPath = URL(fileURLWithPath: sshKeyPath.path + ".pub")
        let fm = FileManager.default

        try fm.createDirectory(
            at: sshDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir.path)

        let hasPrivateKey = try regularFileExists(at: sshKeyPath)
        let hasPublicKey = try regularFileExists(at: publicKeyPath)

        if hasPrivateKey {
            let publicKey = try derivePublicKey()
            let temporaryPublicKey = sshDir.appendingPathComponent(".id_ed25519.pub.\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temporaryPublicKey) }
            let data = Data("\(publicKey) builder@darwin-vz-nix\n".utf8)
            let fd = open(temporaryPublicKey.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            do {
                defer { close(fd) }
                try Self.writeAll(data, to: fd)
                guard fsync(fd) == 0, fchmod(fd, 0o644) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            } catch {
                throw error
            }
            try beforePublicKeyInstall?()
            guard rename(temporaryPublicKey.path, publicKeyPath.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            try setSSHKeyPermissions(publicKeyPath: publicKeyPath)
            return
        } else if hasPublicKey {
            guard unlink(publicKeyPath.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
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
        try setRegularFilePermissions(at: sshKeyPath, mode: 0o600)
        try setRegularFilePermissions(at: publicKeyPath, mode: 0o644)
    }

    private func regularFileExists(at url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw CocoaError(.fileReadUnknown)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw NetworkError.unsafeSSHKeyPath(url.path)
        }
        return true
    }

    private func setRegularFilePermissions(at url: URL, mode: mode_t) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NetworkError.unsafeSSHKeyPath(url.path) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw NetworkError.unsafeSSHKeyPath(url.path)
        }
        guard fchmod(fd, mode) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    // MARK: - Guest IP Discovery

    /// Discover guest VM IP by polling /var/db/dhcpd_leases for the guest hostname,
    /// then verifying the candidate IP via ARP table MAC address check.
    /// macOS's vmnet DHCP server writes lease entries with the hostname reported by the guest.
    func discoverGuestIP(hostname: String = Constants.guestHostname, timeout: TimeInterval = 120, notBefore: Date) async throws -> String {
        let leaseFile = "/var/db/dhcpd_leases"
        let deadline = Date().addingTimeInterval(timeout)
        let mac = macAddress

        var consecutiveLeaseMisses = 0
        var pollMilliseconds = 500
        var cachedLeaseModification: Date?
        var cachedLeaseIP: String?

        while Date() < deadline {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: leaseFile),
               let modification = attributes[.modificationDate] as? Date,
               modification >= notBefore,
               modification != cachedLeaseModification
            {
                cachedLeaseModification = modification
                cachedLeaseIP = parseLeaseFile(
                    path: leaseFile,
                    hostname: hostname,
                    unexpiredAt: UInt64(Date().timeIntervalSince1970)
                )
            }

            // One ARP snapshot is shared by both paths for this iteration.
            let arpIP = Self.readARPTable().flatMap { Self.scanARPTableForMAC($0, expectedMAC: mac) }
            let leaseCandidate = cachedLeaseIP.flatMap { $0 == arpIP ? $0 : nil }
            let fallbackCandidate = consecutiveLeaseMisses >= 2 ? arpIP : nil
            if let ip = leaseCandidate ?? fallbackCandidate,
               Self.isValidIPv4(ip),
               Self.isTCPPortOpen(ip: ip, port: 22)
            { return ip }

            consecutiveLeaseMisses += 1

            try await Task.sleep(for: .milliseconds(pollMilliseconds))
            // Linear backoff (cap 2s) to avoid spawning ~240 arp/nc subprocesses.
            pollMilliseconds = min(pollMilliseconds + 250, 2000)
        }

        throw NetworkError.guestIPNotFound
    }

    /// Parse macOS DHCP lease content for a matching hostname.
    /// This is separated from file I/O to enable unit testing.
    static func parseLeaseContent(_ content: String, hostname: String, unexpiredAt: UInt64) -> String? {
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

            if name == hostname, let ip = ipAddress,
               leaseTimestamp > unexpiredAt, leaseTimestamp >= newestTimestamp
            {
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
        readARPTable().flatMap { scanARPTableForMAC($0, expectedMAC: expectedMAC) }
    }

    private static func readARPTable() -> String? {
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
        guard process.terminationStatus == 0 else { return nil }
        return output
    }

    private func parseLeaseFile(path: String, hostname: String, unexpiredAt: UInt64) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return NetworkManager.parseLeaseContent(content, hostname: hostname, unexpiredAt: unexpiredAt)
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
    @discardableResult
    static func removeKnownHostEntry(
        host: String,
        knownHostsURL: URL,
        afterOpen: (() -> Void)? = nil
    ) -> Bool {
        let parentURL = knownHostsURL.deletingLastPathComponent()
        let leaf = knownHostsURL.lastPathComponent
        guard !leaf.isEmpty, !leaf.contains("/") else { return false }
        let directoryFD = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { return false }
        defer { close(directoryFD) }
        let fd = leaf.withCString { openat(directoryFD, $0, O_RDWR | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var originalInfo = stat()
        guard fstat(fd, &originalInfo) == 0, (originalInfo.st_mode & S_IFMT) == S_IFREG else {
            return false
        }
        guard flock(fd, LOCK_EX) == 0 else { return false }
        defer { flock(fd, LOCK_UN) }

        guard lseek(fd, 0, SEEK_SET) >= 0,
              let originalData = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd()
        else { return false }

        // ssh-keygen gets a private copy, so its path-based rewrite and `.old`
        // backup can never touch or leak into the untrusted source directory.
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("darwin-vz-nix-known-hosts.\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch { return false }
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let temporaryKnownHosts = temporaryDirectory.appendingPathComponent("known_hosts")
        do { try originalData.write(to: temporaryKnownHosts, options: .withoutOverwriting) } catch { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-R", host, "-f", temporaryKnownHosts.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let scrubbedData = try? Data(contentsOf: temporaryKnownHosts)
        else { return false }

        afterOpen?()
        var currentInfo = stat()
        let pathStillNamesOriginal = leaf.withCString {
            fstatat(directoryFD, $0, &currentInfo, AT_SYMLINK_NOFOLLOW) == 0
        }
        guard pathStillNamesOriginal,
              currentInfo.st_dev == originalInfo.st_dev,
              currentInfo.st_ino == originalInfo.st_ino
        else { return false }

        guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) >= 0 else { return false }
        do {
            try writeAll(scrubbedData, to: fd)
            return fsync(fd) == 0
        } catch {
            return false
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
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

    /// Stable identity used by the state-local SSH client. The DHCP address may
    /// change between boots, but the VM host key must remain pinned.
    static let stateSSHHostKeyAlias = "darwin-vz-nix-state"

    /// Evict `darwin-vz-nix_known_hosts` entries for both the current
    /// process's own user and the logged-in macOS console user.
    ///
    /// The darwin-module points plain `ssh darwin-vz-nix` (interactive users)
    /// and `nix.buildMachines` (root's nix-daemon, for distributed builds) at
    /// `~/.ssh/darwin-vz-nix_known_hosts`, connecting via the `Host
    /// darwin-vz-nix` alias through a `ProxyCommand` — so ssh has no
    /// hostname/IP of its own to resolve and records the entry under the
    /// literal alias name, not the guest IP. `scrubKnownHost(ip:)` validates
    /// its argument as an IPv4 address and
    /// would reject the alias outright. Without this, a guest whose host key
    /// changes hard-fails every SSH path outside the `ssh` subcommand.
    ///
    /// Because `destroy` can run as the root/launchd daemon, the console-user
    /// branch restores ownership after the descriptor-based rewrite.
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
    /// `consoleUser` after a root scrub. Without this the user's plain
    /// `ssh darwin-vz-nix` can't append the new host key (the file flips to
    /// root:wheel 0600). Best-effort: any failure must not crash `start`.
    private static func restoreConsoleUserOwnership(of knownHostsURL: URL, to consoleUser: String) {
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
    /// keys into. Pins survive normal restarts and are removed only by destroy.
    func stateKnownHostsURL() -> URL {
        stateDirectory.appendingPathComponent("ssh/known_hosts")
    }

    /// Evict the state-directory pin during explicit destruction/recreation of
    /// the VM identity.
    func scrubStateKnownHosts() {
        Self.removeKnownHostEntry(
            host: Self.stateSSHHostKeyAlias,
            knownHostsURL: stateKnownHostsURL()
        )
    }

    func connectSSH(extraArgs: [String] = []) throws {
        let arguments = try sshArguments(extraArgs: extraArgs)

        // Use execv to replace the current process with ssh.
        // Process() doesn't transfer terminal control to the child,
        // which prevents the login shell from starting interactively.
        let allocatedArgs = arguments.map { strdup($0) }
        let cArgs = allocatedArgs + [nil]
        execv("/usr/bin/ssh", cArgs)

        // execv only returns on failure
        let execError = errno
        allocatedArgs.forEach { free($0) }
        throw NetworkError.sshConnectionFailed(execError)
    }

    static func knownHostsContainsEntry(host: String, at url: URL) -> Bool {
        knownHostsEntries(at: url).contains { line in
            guard let hosts = line.split(whereSeparator: { $0.isWhitespace }).first else { return false }
            return hosts.split(separator: ",").contains(Substring(host))
        }
    }

    func sshArguments(extraArgs: [String] = []) throws -> [String] {
        guard FileManager.default.fileExists(atPath: sshKeyPath.path) else {
            throw NetworkError.sshKeyNotFound(sshKeyPath.path)
        }

        let guestIP = try readGuestIP()
        let knownHostsURL = stateKnownHostsURL()
        let checkingMode = Self.knownHostsContainsEntry(
            host: Self.stateSSHHostKeyAlias,
            at: knownHostsURL
        ) ? "yes" : "accept-new"

        var arguments = [
            "/usr/bin/ssh",
            "-i", sshKeyPath.path,
            "-o", "StrictHostKeyChecking=\(checkingMode)",
            "-o", "UserKnownHostsFile=\(knownHostsURL.path)",
            "-o", "HostKeyAlias=\(Self.stateSSHHostKeyAlias)",
            "-o", "HashKnownHosts=no",
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
        return arguments
    }

    private static func knownHostsEntries(at url: URL) -> [Substring] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd(),
              let content = String(data: data, encoding: .utf8)
        else { return [] }
        return content.split(whereSeparator: { $0.isNewline }).filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                && !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}
