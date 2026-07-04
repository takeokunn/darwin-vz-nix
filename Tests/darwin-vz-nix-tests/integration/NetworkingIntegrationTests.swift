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
    func removeKnownHostEntryLeavesRecoverableOldBackup() throws {
        // ssh-keygen -R rewrites in place and drops a "<file>.old" backup. The
        // scrubUserKnownHosts fix deletes that sibling for the console-user
        // branch; here we assert the backup ssh-keygen leaves is itself owned
        // by the current user (so no root-owned cruft is produced off-root) and
        // that deleting it is a no-op that leaves the live file intact.
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let knownHostsURL = tempDir.appendingPathComponent("known_hosts")
        let staleEntry = "darwin-vz-nix ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP4stale0000000000000000000000000000\n"
        try staleEntry.write(to: knownHostsURL, atomically: true, encoding: .utf8)

        NetworkManager.removeKnownHostEntry(host: "darwin-vz-nix", knownHostsURL: knownHostsURL)

        let backupURL = URL(fileURLWithPath: knownHostsURL.path + ".old")
        if FileManager.default.fileExists(atPath: backupURL.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: backupURL.path)
            let ownerID = attrs[.ownerAccountID] as? UInt32
            #expect(ownerID == getuid())
            try? FileManager.default.removeItem(at: backupURL)
        }

        // The live known_hosts survives regardless of backup handling.
        #expect(FileManager.default.fileExists(atPath: knownHostsURL.path))
        let remaining = try String(contentsOf: knownHostsURL, encoding: .utf8)
        #expect(!remaining.contains("darwin-vz-nix"))
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
