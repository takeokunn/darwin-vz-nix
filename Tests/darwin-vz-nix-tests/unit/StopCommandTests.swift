import ArgumentParser
@testable import DarwinVZNixLib
import Foundation
import Testing

struct StopCommandTests {
    @Test
    func defaultForceIsFalse() throws {
        let cmd = try Stop.parse([])
        #expect(cmd.force == false)
    }

    @Test
    func forceFlag() throws {
        let cmd = try Stop.parse(["--force"])
        #expect(cmd.force == true)
    }

    @Test
    func abstractIsNonEmpty() {
        #expect(!Stop.configuration.abstract.isEmpty)
    }

    @Test
    func missingPIDCleansGuestIP() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let guestIPFile = stateDirectory.appendingPathComponent("guest-ip")
        try "192.0.2.10".write(to: guestIPFile, atomically: true, encoding: .utf8)

        var cmd = try Stop.parse(["--state-dir", stateDirectory.path])
        await #expect(throws: CleanExit.self) {
            try await cmd.run()
        }

        #expect(!FileManager.default.fileExists(atPath: guestIPFile.path))
    }

    @Test
    func stalePIDCleansRuntimeFiles() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let pidFile = stateDirectory.appendingPathComponent("vm.pid")
        let guestIPFile = stateDirectory.appendingPathComponent("guest-ip")
        try "999999".write(to: pidFile, atomically: true, encoding: .utf8)
        try "192.0.2.10".write(to: guestIPFile, atomically: true, encoding: .utf8)

        var cmd = try Stop.parse(["--state-dir", stateDirectory.path])
        await #expect(throws: CleanExit.self) {
            try await cmd.run()
        }

        #expect(!FileManager.default.fileExists(atPath: pidFile.path))
        #expect(!FileManager.default.fileExists(atPath: guestIPFile.path))
    }
}
