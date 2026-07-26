@testable import DarwinVZNixLib
import Foundation
import Testing

@Suite(.tags(.integration))
struct NetworkingIntegrationTests {
    // MARK: - Guest IP Roundtrip

    @Test
    func guestIPRoundtrip() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let manager = NetworkManager(stateDirectory: tempDir)
        try manager.writeGuestIP("192.168.64.2")
        let ip = try manager.readGuestIP()
        #expect(ip == "192.168.64.2")
    }

    @Test
    func writeGuestIPCreatesStateDirectory() throws {
        let parentDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: parentDir) }

        let stateDir = parentDir.appendingPathComponent("state", isDirectory: true)
        let manager = NetworkManager(stateDirectory: stateDir)
        try manager.writeGuestIP("192.168.64.2")

        #expect(FileManager.default.fileExists(atPath: stateDir.path))
        #expect(try manager.readGuestIP() == "192.168.64.2")
    }

    @Test
    func readGuestIPNonExistent() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let manager = NetworkManager(stateDirectory: tempDir)
        #expect(throws: NetworkError.self) {
            try manager.readGuestIP()
        }
    }

    @Test
    func writeGuestIPIsWorldReadable() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let manager = NetworkManager(stateDirectory: tempDir)
        try manager.writeGuestIP("192.168.64.2")

        let guestIPFileURL = VMConfig.guestIPFileURL(for: tempDir)
        let attrs = try FileManager.default.attributesOfItem(atPath: guestIPFileURL.path)
        let posix = attrs[.posixPermissions] as? Int
        #expect(posix == Int(0o644))
    }

    // MARK: - Known Hosts Scrubbing

    @Test
    func scrubKnownHostRemovesStaleEntry() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let knownHostsURL = tempDir.appendingPathComponent("known_hosts")
        let staleEntry = "192.168.64.9 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP4stale0000000000000000000000000000\n"
        try staleEntry.write(to: knownHostsURL, atomically: true, encoding: .utf8)

        NetworkManager.scrubKnownHost(ip: "192.168.64.9", knownHostsURL: knownHostsURL)

        let remaining = try String(contentsOf: knownHostsURL, encoding: .utf8)
        #expect(!remaining.contains("192.168.64.9"))
    }

    @Test
    func removeKnownHostEntryRemovesAliasEntry() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let knownHostsURL = tempDir.appendingPathComponent("known_hosts")
        let staleEntry = "darwin-vz-nix ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP4stale0000000000000000000000000000\n"
        try staleEntry.write(to: knownHostsURL, atomically: true, encoding: .utf8)

        NetworkManager.removeKnownHostEntry(host: "darwin-vz-nix", knownHostsURL: knownHostsURL)

        let remaining = try String(contentsOf: knownHostsURL, encoding: .utf8)
        #expect(!remaining.contains("darwin-vz-nix"))
    }

    @Test
    func removeKnownHostEntryKeepsFileOwnedByCurrentUser() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let knownHostsURL = tempDir.appendingPathComponent("known_hosts")
        let staleEntry = "darwin-vz-nix ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP4stale0000000000000000000000000000\n"
        try staleEntry.write(to: knownHostsURL, atomically: true, encoding: .utf8)

        NetworkManager.removeKnownHostEntry(host: "darwin-vz-nix", knownHostsURL: knownHostsURL)

        // In the normal (non-root) case the rewritten file must stay owned by
        // the current user so a later `ssh` can still append host keys.
        let attrs = try FileManager.default.attributesOfItem(atPath: knownHostsURL.path)
        let ownerID = attrs[.ownerAccountID] as? UInt32
        #expect(ownerID == getuid())
    }

    @Test
    func removeKnownHostEntryDoesNotLeaveOldBackup() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let knownHostsURL = tempDir.appendingPathComponent("known_hosts")
        let staleEntry = "darwin-vz-nix ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP4stale0000000000000000000000000000\n"
        try staleEntry.write(to: knownHostsURL, atomically: true, encoding: .utf8)

        NetworkManager.removeKnownHostEntry(host: "darwin-vz-nix", knownHostsURL: knownHostsURL)

        let backupURL = URL(fileURLWithPath: knownHostsURL.path + ".old")
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))

        // The live known_hosts survives regardless of backup handling.
        #expect(FileManager.default.fileExists(atPath: knownHostsURL.path))
        let remaining = try String(contentsOf: knownHostsURL, encoding: .utf8)
        #expect(!remaining.contains("darwin-vz-nix"))
    }

    @Test
    func scrubStateKnownHostsRemovesOnlyStableAlias() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let sshDir = tempDir.appendingPathComponent("ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        let knownHostsURL = sshDir.appendingPathComponent("known_hosts")
        let entries = """
        darwin-vz-nix-state ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP4stale0000000000000000000000000000
        192.168.64.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP4fresh0000000000000000000000000000
        """
        try (entries + "\n").write(to: knownHostsURL, atomically: true, encoding: .utf8)

        let manager = NetworkManager(stateDirectory: tempDir)
        manager.scrubStateKnownHosts()

        // Explicit destroy removes only the selected VM's pin; other VMs'
        // pins in the same state file must survive.
        let remaining = try String(contentsOf: knownHostsURL, encoding: .utf8)
        #expect(!remaining.contains("darwin-vz-nix-state"))
        #expect(remaining.contains("192.168.64.10"))
    }

    @Test
    func removeKnownHostEntryRefusesSymlink() throws {
        // A symlink standing in for the known_hosts file must be refused, so a
        // root daemon can't be tricked into rewriting the link's target (e.g.
        // /etc/sudoers) via `ssh-keygen -R`.
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let target = tempDir.appendingPathComponent("protected")
        try "PROTECTED\n".write(to: target, atomically: true, encoding: .utf8)
        let link = tempDir.appendingPathComponent("known_hosts")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        NetworkManager.removeKnownHostEntry(host: "darwin-vz-nix", knownHostsURL: link)

        // The symlink target is untouched (ssh-keygen never ran against it), and
        // the symlink itself is left in place rather than followed.
        #expect(try String(contentsOf: target, encoding: .utf8) == "PROTECTED\n")
        let linkAttrs = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect(linkAttrs[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test
    func removeKnownHostEntryRejectsPathReplacementAfterOpen() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let knownHostsURL = tempDir.appendingPathComponent("known_hosts")
        let displacedURL = tempDir.appendingPathComponent("known_hosts.displaced")
        let sentinelURL = tempDir.appendingPathComponent("sentinel")
        let staleEntry = "darwin-vz-nix ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP4stale0000000000000000000000000000\n"
        try staleEntry.write(to: knownHostsURL, atomically: true, encoding: .utf8)
        try "SENTINEL\n".write(to: sentinelURL, atomically: true, encoding: .utf8)

        let removed = NetworkManager.removeKnownHostEntry(
            host: "darwin-vz-nix",
            knownHostsURL: knownHostsURL,
            afterOpen: {
                try! FileManager.default.moveItem(at: knownHostsURL, to: displacedURL)
                try! FileManager.default.createSymbolicLink(
                    at: knownHostsURL,
                    withDestinationURL: sentinelURL
                )
            }
        )

        #expect(!removed)
        #expect(try String(contentsOf: sentinelURL, encoding: .utf8) == "SENTINEL\n")
        #expect(try String(contentsOf: displacedURL, encoding: .utf8) == staleEntry)
        #expect(!FileManager.default.fileExists(atPath: knownHostsURL.path + ".old"))
    }

    @Test
    func scrubKnownHostIgnoresMissingFile() {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let knownHostsURL = tempDir.appendingPathComponent("does-not-exist")
        NetworkManager.scrubKnownHost(ip: "192.168.64.9", knownHostsURL: knownHostsURL)

        #expect(!FileManager.default.fileExists(atPath: knownHostsURL.path))
    }

    // MARK: - SSH Key Generation

    @Test
    func ensureSSHKeysCreatesKeyPair() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let manager = NetworkManager(stateDirectory: tempDir)
        try manager.ensureSSHKeys()

        let privateKeyPath = VMConfig.sshKeyURL(for: tempDir).path
        let publicKeyPath = privateKeyPath + ".pub"
        #expect(FileManager.default.fileExists(atPath: privateKeyPath))
        #expect(FileManager.default.fileExists(atPath: publicKeyPath))
    }

    @Test
    func ensureSSHKeysIdempotent() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let manager = NetworkManager(stateDirectory: tempDir)
        try manager.ensureSSHKeys()

        let privateKeyURL = VMConfig.sshKeyURL(for: tempDir)
        let firstContent = try String(contentsOf: privateKeyURL, encoding: .utf8)

        try manager.ensureSSHKeys()

        let secondContent = try String(contentsOf: privateKeyURL, encoding: .utf8)
        #expect(firstContent == secondContent)
    }

    @Test
    func ensureSSHKeysRepairsMissingPublicKey() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let manager = NetworkManager(stateDirectory: tempDir)
        try manager.ensureSSHKeys()

        let privateKeyURL = VMConfig.sshKeyURL(for: tempDir)
        let publicKeyURL = URL(fileURLWithPath: privateKeyURL.path + ".pub")
        let privateKey = try String(contentsOf: privateKeyURL, encoding: .utf8)
        try FileManager.default.removeItem(at: publicKeyURL)

        try manager.ensureSSHKeys()

        #expect(FileManager.default.fileExists(atPath: publicKeyURL.path))
        let repairedPrivateKey = try String(contentsOf: privateKeyURL, encoding: .utf8)
        let repairedPublicKey = try String(contentsOf: publicKeyURL, encoding: .utf8)
        #expect(repairedPrivateKey == privateKey)
        #expect(repairedPublicKey.hasPrefix("ssh-ed25519"))
    }

    @Test
    func ensureSSHKeysRepairsMismatchedPublicKey() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let manager = NetworkManager(stateDirectory: tempDir)
        try manager.ensureSSHKeys()

        let privateKeyURL = VMConfig.sshKeyURL(for: tempDir)
        let publicKeyURL = URL(fileURLWithPath: privateKeyURL.path + ".pub")
        let privateKey = try Data(contentsOf: privateKeyURL)
        let expectedPublicKey = try String(contentsOf: publicKeyURL, encoding: .utf8)
        try "ssh-ed25519 AAAA-mismatched builder@darwin-vz-nix\n".write(
            to: publicKeyURL,
            atomically: true,
            encoding: .utf8
        )

        try manager.ensureSSHKeys()

        #expect(try Data(contentsOf: privateKeyURL) == privateKey)
        let expectedKeyMaterial = expectedPublicKey.split(whereSeparator: { $0.isWhitespace }).prefix(2)
        let repairedPublicKey = try String(contentsOf: publicKeyURL, encoding: .utf8)
        let repairedKeyMaterial = repairedPublicKey.split(whereSeparator: { $0.isWhitespace }).prefix(2)
        #expect(repairedKeyMaterial.elementsEqual(expectedKeyMaterial))
    }

    @Test
    func ensureSSHKeysPreservesPrivateKeyWhenPublicKeyInstallFails() throws {
        enum InjectedFailure: Error { case stop }

        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let manager = NetworkManager(stateDirectory: tempDir)
        try manager.ensureSSHKeys()

        let privateKeyURL = VMConfig.sshKeyURL(for: tempDir)
        let publicKeyURL = URL(fileURLWithPath: privateKeyURL.path + ".pub")
        let privateKey = try Data(contentsOf: privateKeyURL)
        try FileManager.default.removeItem(at: publicKeyURL)

        #expect(throws: InjectedFailure.self) {
            try manager.ensureSSHKeys(beforePublicKeyInstall: { throw InjectedFailure.stop })
        }

        #expect(try Data(contentsOf: privateKeyURL) == privateKey)
        #expect(!FileManager.default.fileExists(atPath: publicKeyURL.path))
    }

    @Test
    func ensureSSHKeysRejectsPublicKeySymlink() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let manager = NetworkManager(stateDirectory: tempDir)
        try manager.ensureSSHKeys()

        let privateKeyURL = VMConfig.sshKeyURL(for: tempDir)
        let publicKeyURL = URL(fileURLWithPath: privateKeyURL.path + ".pub")
        let sentinelURL = tempDir.appendingPathComponent("sentinel")
        let privateKey = try Data(contentsOf: privateKeyURL)
        try FileManager.default.removeItem(at: publicKeyURL)
        try "SENTINEL\n".write(to: sentinelURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: publicKeyURL, withDestinationURL: sentinelURL)

        #expect(throws: NetworkError.self) {
            try manager.ensureSSHKeys()
        }

        #expect(try Data(contentsOf: privateKeyURL) == privateKey)
        #expect(try String(contentsOf: sentinelURL, encoding: .utf8) == "SENTINEL\n")
    }

    @Test
    func ensureSSHKeysKeyFormat() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let manager = NetworkManager(stateDirectory: tempDir)
        try manager.ensureSSHKeys()

        let publicKeyPath = VMConfig.sshKeyURL(for: tempDir).path + ".pub"
        let publicKey = try String(contentsOfFile: publicKeyPath, encoding: .utf8)
        #expect(publicKey.hasPrefix("ssh-ed25519"))
    }
}
