@testable import DarwinVZNixLib
import Foundation
import Testing

struct VirtioFSTests {
    @Test
    func rosettaNotAvailableDescription() throws {
        let error = VirtioFSError.rosettaNotAvailable
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("Rosetta"))
        #expect(desc.contains("not available"))
    }

    @Test
    func rosettaNotInstalledDescription() throws {
        let error = VirtioFSError.rosettaNotInstalled
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("not installed"))
    }

    @Test
    func sharedDirectoryFailedDescription() throws {
        let reason = "/nix/store does not exist"
        let error = VirtioFSError.sharedDirectoryFailed(reason)
        let desc = try #require(error.errorDescription)
        #expect(desc.contains(reason))
        #expect(desc.contains("shared directory"))
    }

    // MARK: - SSH public-key-only share (security)

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("virtiofs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test
    func sshShareExposesOnlyPublicKey() throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }

        let sshDir = root.appendingPathComponent("ssh", isDirectory: true)
        try fm.createDirectory(at: sshDir, withIntermediateDirectories: true)
        // Simulate a real key pair: private key MUST NOT leak into the share.
        try "PRIVATE".write(to: sshDir.appendingPathComponent("id_ed25519"), atomically: true, encoding: .utf8)
        try "ssh-ed25519 AAAA builder@darwin-vz-nix"
            .write(to: sshDir.appendingPathComponent("id_ed25519.pub"), atomically: true, encoding: .utf8)

        let shareDir = root.appendingPathComponent("ssh-pub", isDirectory: true)
        _ = try VirtioFSManager.createSSHKeysShare(sshDirectory: sshDir, shareDirectory: shareDir)

        let shared = try fm.contentsOfDirectory(atPath: shareDir.path).sorted()
        #expect(shared == ["id_ed25519.pub"])
        #expect(!fm.fileExists(atPath: shareDir.appendingPathComponent("id_ed25519").path))
    }

    @Test
    func assertNoPrivateKeyRejectsPrivateMaterial() throws {
        let fm = FileManager.default
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        try "ssh-ed25519 AAAA".write(to: dir.appendingPathComponent("id_ed25519.pub"), atomically: true, encoding: .utf8)
        try "PRIVATE".write(to: dir.appendingPathComponent("id_ed25519"), atomically: true, encoding: .utf8)

        #expect(throws: VirtioFSError.self) {
            try VirtioFSManager.assertNoPrivateKey(in: dir)
        }
    }

    @Test
    func symlinkedPublicKeyIsRejected() throws {
        // A symlinked id_ed25519.pub pointing at the private key must NOT be
        // copied into the guest share (it would leak the private key).
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }

        let sshDir = root.appendingPathComponent("ssh", isDirectory: true)
        try fm.createDirectory(at: sshDir, withIntermediateDirectories: true)
        let privateKey = sshDir.appendingPathComponent("id_ed25519")
        try "PRIVATE-SECRET".write(to: privateKey, atomically: true, encoding: .utf8)
        // id_ed25519.pub is a symlink to the private key.
        try fm.createSymbolicLink(
            at: sshDir.appendingPathComponent("id_ed25519.pub"),
            withDestinationURL: privateKey
        )

        let shareDir = root.appendingPathComponent("ssh-pub", isDirectory: true)
        #expect(throws: VirtioFSError.self) {
            try VirtioFSManager.createSSHKeysShare(sshDirectory: sshDir, shareDirectory: shareDir)
        }
        // And nothing leaked into the share.
        let shared = (try? fm.contentsOfDirectory(atPath: shareDir.path)) ?? []
        #expect(!shared.contains { (try? String(contentsOf: shareDir.appendingPathComponent($0), encoding: .utf8)) == "PRIVATE-SECRET" })
    }

    @Test
    func missingPublicKeyThrows() throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let sshDir = root.appendingPathComponent("ssh", isDirectory: true)
        try fm.createDirectory(at: sshDir, withIntermediateDirectories: true)

        #expect(throws: VirtioFSError.self) {
            try VirtioFSManager.createSSHKeysShare(
                sshDirectory: sshDir,
                shareDirectory: root.appendingPathComponent("ssh-pub", isDirectory: true)
            )
        }
    }
}
