import ArgumentParser
@testable import DarwinVZNixLib
import Foundation
import Testing

struct DestroyCommandTests {
    @Test
    func defaultFlags() throws {
        let cmd = try Destroy.parse([])
        #expect(cmd.yes == false)
        #expect(cmd.stateDir == nil)
    }

    @Test
    func yesFlag() throws {
        let cmd = try Destroy.parse(["--yes"])
        #expect(cmd.yes == true)
    }

    @Test
    func stateDirOption() throws {
        let cmd = try Destroy.parse(["--state-dir", "/tmp/custom"])
        #expect(cmd.stateDir == "/tmp/custom")
    }

    @Test
    func combinedOptions() throws {
        let cmd = try Destroy.parse(["--yes", "--state-dir", "/custom/path"])
        #expect(cmd.yes == true)
        #expect(cmd.stateDir == "/custom/path")
    }

    @Test
    func testAbstract() {
        #expect(!Destroy.configuration.abstract.isEmpty)
        #expect(Destroy.configuration.abstract.lowercased().contains("destroy"))
    }

    @Test
    func destroyWithReusedPID() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let disk = stateDirectory.appendingPathComponent("disk.img")
        let guestIP = stateDirectory.appendingPathComponent("guest-ip")
        let sshDir = stateDirectory.appendingPathComponent("ssh", isDirectory: true)
        try Data("disk".utf8).write(to: disk)
        try Data("192.168.64.2".utf8).write(to: guestIP)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        try Data("key".utf8).write(to: sshDir.appendingPathComponent("id_ed25519"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["120"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let record = VMProcessRecord(
            pid: process.processIdentifier,
            executablePath: "/definitely/not/bin/darwin-vz-nix",
            stateDirectory: stateDirectory.path,
            startedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder
            .encode(record)
            .write(to: stateDirectory.appendingPathComponent("vm.pid"))

        var cmd = try Destroy.parse(["--yes", "--state-dir", stateDirectory.path])
        try await cmd.run()

        #expect(process.isRunning == true)
        #expect(FileManager.default.fileExists(atPath: disk.path) == false)
        #expect(FileManager.default.fileExists(atPath: guestIP.path) == false)
        #expect(FileManager.default.fileExists(atPath: sshDir.path) == false)
        #expect(
            FileManager.default.fileExists(
                atPath: stateDirectory.appendingPathComponent("vm.pid").path
            ) == false
        )
    }

    /// `destroy` must remove EVERY state artifact, including the Nix GC-root
    /// directory (which pins the guest kernel/initrd/system store paths) and the
    /// public-key VirtioFS share. Leaving `gcroots/` behind keeps store paths
    /// un-collectable forever, defeating the purpose of destroy.
    @Test
    func destroyRemovesGCRootsAndPublicShare() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let gcroots = stateDirectory.appendingPathComponent("gcroots", isDirectory: true)
        let sshPub = stateDirectory.appendingPathComponent("ssh-pub", isDirectory: true)
        try FileManager.default.createDirectory(at: gcroots, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sshPub, withIntermediateDirectories: true)
        try Data("root".utf8).write(to: gcroots.appendingPathComponent("kernel"))
        try Data("ssh-ed25519 AAAA builder@darwin-vz-nix".utf8)
            .write(to: sshPub.appendingPathComponent("id_ed25519.pub"))

        var cmd = try Destroy.parse(["--yes", "--state-dir", stateDirectory.path])
        try await cmd.run()

        #expect(FileManager.default.fileExists(atPath: gcroots.path) == false)
        #expect(FileManager.default.fileExists(atPath: sshPub.path) == false)
    }
}
