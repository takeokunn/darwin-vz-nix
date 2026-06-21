import ArgumentParser
@testable import DarwinVZNixLib
import Foundation
import Testing

struct StatusCommandTests {
    @Test
    func jsonRoundtripRunning() throws {
        let original = VMStatusOutput(running: true, pid: 1234, stateDirectory: "/tmp/test")
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VMStatusOutput.self, from: data)
        #expect(decoded.running == true)
        #expect(decoded.pid == 1234)
        #expect(decoded.stateDirectory == "/tmp/test")
    }

    @Test
    func jsonRoundtripStopped() throws {
        let original = VMStatusOutput(running: false, pid: nil, stateDirectory: "/tmp/test")
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VMStatusOutput.self, from: data)
        #expect(decoded.running == false)
        #expect(decoded.pid == nil)
    }

    @Test
    func jsonRunningWithStateDirectory() throws {
        let original = VMStatusOutput(running: true, pid: 42, stateDirectory: "/var/lib/vm")
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VMStatusOutput.self, from: data)
        #expect(decoded.running == true)
        #expect(decoded.pid == 42)
        #expect(decoded.stateDirectory == "/var/lib/vm")
    }

    @Test
    func defaultJsonIsFalse() throws {
        let cmd = try Status.parse([])
        #expect(cmd.json == false)
    }

    @Test
    func jsonFlag() throws {
        let cmd = try Status.parse(["--json"])
        #expect(cmd.json == true)
    }

    @Test
    func jsonCleansStaleRuntimeFiles() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let pidFile = stateDirectory.appendingPathComponent("vm.pid")
        let guestIPFile = stateDirectory.appendingPathComponent("guest-ip")
        try "999999".write(to: pidFile, atomically: true, encoding: .utf8)
        try "192.0.2.10".write(to: guestIPFile, atomically: true, encoding: .utf8)

        var cmd = try Status.parse(["--json", "--state-dir", stateDirectory.path])
        try await cmd.run()

        #expect(!FileManager.default.fileExists(atPath: pidFile.path))
        #expect(!FileManager.default.fileExists(atPath: guestIPFile.path))
    }

    @Test
    func jsonCleansInvalidPIDFile() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let pidFile = stateDirectory.appendingPathComponent("vm.pid")
        let guestIPFile = stateDirectory.appendingPathComponent("guest-ip")
        try "not-a-pid".write(to: pidFile, atomically: true, encoding: .utf8)
        try "192.0.2.10".write(to: guestIPFile, atomically: true, encoding: .utf8)

        var cmd = try Status.parse(["--json", "--state-dir", stateDirectory.path])
        try await cmd.run()

        #expect(!FileManager.default.fileExists(atPath: pidFile.path))
        #expect(!FileManager.default.fileExists(atPath: guestIPFile.path))
    }

    @Test
    func testCleanupStoppedRuntimeFiles() throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let pidFile = stateDirectory.appendingPathComponent("vm.pid")
        let guestIPFile = stateDirectory.appendingPathComponent("guest-ip")
        try "999999".write(to: pidFile, atomically: true, encoding: .utf8)
        try "192.0.2.10".write(to: guestIPFile, atomically: true, encoding: .utf8)

        Status.cleanupStoppedRuntimeFiles(in: stateDirectory)

        #expect(!FileManager.default.fileExists(atPath: pidFile.path))
        #expect(!FileManager.default.fileExists(atPath: guestIPFile.path))
    }
}
