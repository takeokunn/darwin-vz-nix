import ArgumentParser
@testable import DarwinVZNixLib
import Foundation
import Testing

struct StartCommandTests {
    @Test
    func defaultValues() throws {
        let cmd = try Start.parse(["--kernel", "/tmp/k", "--initrd", "/tmp/i"])
        #expect(cmd.cores == 4)
        #expect(cmd.memory == 8192)
        #expect(cmd.diskSize == "100G")
        #expect(cmd.rosetta == true)
        #expect(cmd.shareNixStore == true)
        #expect(cmd.idleTimeout == 0)
        #expect(cmd.verbose == false)
    }

    @Test
    func abstractIsNonEmpty() {
        #expect(!Start.configuration.abstract.isEmpty)
    }

    @Test
    func cleanupBeforeStartRemovesGuestIPWithoutPID() throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let config = try makeConfig(stateDirectory: stateDirectory)
        let guestIPFile = stateDirectory.appendingPathComponent("guest-ip")
        try "192.0.2.10".write(to: guestIPFile, atomically: true, encoding: .utf8)

        try Start.cleanupRuntimeFilesBeforeStart(config: config)

        #expect(!FileManager.default.fileExists(atPath: guestIPFile.path))
    }

    @Test
    func cleanupBeforeStartRemovesStaleRuntimeFiles() throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let config = try makeConfig(stateDirectory: stateDirectory)
        let pidFile = stateDirectory.appendingPathComponent("vm.pid")
        let guestIPFile = stateDirectory.appendingPathComponent("guest-ip")
        try "999999".write(to: pidFile, atomically: true, encoding: .utf8)
        try "192.0.2.10".write(to: guestIPFile, atomically: true, encoding: .utf8)

        try Start.cleanupRuntimeFilesBeforeStart(config: config)

        #expect(!FileManager.default.fileExists(atPath: pidFile.path))
        #expect(!FileManager.default.fileExists(atPath: guestIPFile.path))
    }

    @Test
    func cleanupBeforeStartRejectsRunningProcess() throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let config = try makeConfig(stateDirectory: stateDirectory)
        let pidFile = stateDirectory.appendingPathComponent("vm.pid")
        // Simulate a running VM the way production records it: a full PID record
        // for the current process, including its executable path (so the hardened
        // executable-match logic recognizes it as ours).
        let record = VMProcessRecord(
            pid: ProcessInfo.processInfo.processIdentifier,
            executablePath: VMManager.currentExecutablePath(),
            stateDirectory: stateDirectory.path,
            startedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: pidFile)

        // A running VM is an operational condition: exit 3, not a usage error.
        #expect(throws: ExitCode(ExitStatus.operational)) {
            try Start.cleanupRuntimeFilesBeforeStart(config: config)
        }

        #expect(FileManager.default.fileExists(atPath: pidFile.path))
    }

    /// Invalid numeric configuration (cores < 1) is a usage error: exit 64
    /// (EX_USAGE), matching ArgumentParser's own parse-error code — not the
    /// generic failure code 1. `run()` throws before booting anything.
    @Test
    func invalidCoreCountExitsWithUsageStatus() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        var cmd = try Start.parse([
            "--kernel", "/nonexistent/Image",
            "--initrd", "/nonexistent/initrd",
            "--cores", "0",
            "--state-dir", stateDirectory.path,
        ])
        await #expect(throws: ExitCode(ExitStatus.usage)) {
            try await cmd.run()
        }
    }

    /// A missing kernel/initrd artifact is likewise invalid configuration: exit
    /// 64, not 1. Guards the exit-code contract for the most common first-run
    /// failure (artifacts not built yet).
    @Test
    func missingArtifactsExitWithUsageStatus() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        var cmd = try Start.parse([
            "--kernel", "/nonexistent/Image",
            "--initrd", "/nonexistent/initrd",
            "--state-dir", stateDirectory.path,
        ])
        await #expect(throws: ExitCode(ExitStatus.usage)) {
            try await cmd.run()
        }
    }

    @Test
    func stateDirectoryLockIsExclusive() {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        // First acquisition succeeds and holds the lock.
        let first = Start.tryLockStateDirectory(stateDirectory)
        #expect(first >= 0)

        // A second, concurrent acquisition on the same state directory must fail
        // (this is what stops two `start`s from opening disk.img read-write).
        let second = Start.tryLockStateDirectory(stateDirectory)
        #expect(second < 0)

        // Releasing the first lets a later acquisition succeed again.
        close(first)
        let third = Start.tryLockStateDirectory(stateDirectory)
        #expect(third >= 0)
        close(third)
    }

    private func makeConfig(stateDirectory: URL) throws -> VMConfig {
        let kernel = stateDirectory.appendingPathComponent("Image")
        let initrd = stateDirectory.appendingPathComponent("initrd")
        FileManager.default.createFile(atPath: kernel.path, contents: Data("kernel".utf8))
        FileManager.default.createFile(atPath: initrd.path, contents: Data("initrd".utf8))

        return VMConfig(
            kernelURL: kernel,
            initrdURL: initrd,
            stateDirectory: stateDirectory
        )
    }
}
