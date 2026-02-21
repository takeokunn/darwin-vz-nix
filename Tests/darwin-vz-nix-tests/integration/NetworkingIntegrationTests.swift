@testable import DarwinVZNixLib
import Foundation
import Testing

@Suite("Networking Integration", .tags(.integration))
struct NetworkingIntegrationTests {
    // MARK: - Guest IP Roundtrip

    @Test("writeGuestIP then readGuestIP returns same IP")
    func guestIPRoundtrip() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let manager = NetworkManager(stateDirectory: tempDir)
        try manager.writeGuestIP("192.168.64.2")
        let ip = try manager.readGuestIP()
        #expect(ip == "192.168.64.2")
    }

    @Test("readGuestIP throws guestIPNotFound for non-existent file")
    func readGuestIPNonExistent() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let manager = NetworkManager(stateDirectory: tempDir)
        #expect(throws: NetworkError.self) {
            try manager.readGuestIP()
        }
    }

    // MARK: - SSH Key Generation

    @Test("ensureSSHKeys creates key pair files")
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

    @Test("ensureSSHKeys is idempotent and does not overwrite existing keys")
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

    @Test("ensureSSHKeys generates ed25519 public key")
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
