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
