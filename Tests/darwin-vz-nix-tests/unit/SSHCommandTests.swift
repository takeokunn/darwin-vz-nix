import ArgumentParser
@testable import DarwinVZNixLib
import Foundation
import Testing

struct SSHCommandTests {
    @Test
    func defaultExtraArgsEmpty() throws {
        let cmd = try SSH.parse([])
        #expect(cmd.extraArgs == [])
    }

    @Test
    func passthroughArgs() throws {
        let cmd = try SSH.parse(["--", "-v"])
        #expect(cmd.extraArgs == ["-v"])
    }

    @Test
    func abstractIsNonEmpty() {
        #expect(!SSH.configuration.abstract.isEmpty)
    }

    @Test
    func recordedVMIsRunningRejectsMissingRecord() {
        #expect(SSH.recordedVMIsRunning(nil, pidFileURL: URL(fileURLWithPath: "/tmp/vm.pid")) == false)
    }

    @Test
    func recordedVMIsRunningAcceptsCurrentExecutableRecord() throws {
        let executablePath = try #require(VMManager.currentExecutablePath())
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }
        let record = VMProcessRecord(
            pid: ProcessInfo.processInfo.processIdentifier,
            executablePath: executablePath,
            stateDirectory: stateDirectory.path,
            startedAt: Date(),
            processStartTimeMicroseconds: VMManager.processStartTimeMicroseconds(
                for: ProcessInfo.processInfo.processIdentifier
            )
        )

        #expect(SSH.recordedVMIsRunning(
            record, pidFileURL: stateDirectory.appendingPathComponent("vm.pid")
        ) == true)
    }

    @Test
    func recordedVMIsRunningRejectsNonmatchingExecutableRecord() {
        let record = VMProcessRecord(
            pid: ProcessInfo.processInfo.processIdentifier,
            executablePath: "/definitely/not/current/darwin-vz-nix",
            stateDirectory: "/tmp/darwin-vz-nix-tests",
            startedAt: Date()
        )

        #expect(SSH.recordedVMIsRunning(
            record, pidFileURL: URL(fileURLWithPath: "/tmp/darwin-vz-nix-tests/vm.pid")
        ) == false)
    }

    @Test
    func runCleansStaleRuntimeFiles() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let record = VMProcessRecord(
            pid: ProcessInfo.processInfo.processIdentifier,
            executablePath: "/definitely/not/current/darwin-vz-nix",
            stateDirectory: stateDirectory.path,
            startedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let pidFile = stateDirectory.appendingPathComponent("vm.pid")
        let guestIPFile = stateDirectory.appendingPathComponent("guest-ip")
        try encoder.encode(record).write(to: pidFile)
        try "192.0.2.10".write(to: guestIPFile, atomically: true, encoding: .utf8)

        var cmd = try SSH.parse(["--state-dir", stateDirectory.path])
        // No running VM is an operational condition: exit 3, not a usage error.
        await #expect(throws: ExitCode(ExitStatus.operational)) {
            try await cmd.run()
        }

        #expect(!FileManager.default.fileExists(atPath: pidFile.path))
        #expect(!FileManager.default.fileExists(atPath: guestIPFile.path))
    }
}
