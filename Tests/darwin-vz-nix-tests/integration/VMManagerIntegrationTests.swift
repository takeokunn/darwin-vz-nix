@testable import DarwinVZNixLib
import Foundation
import Testing

@Suite("VMManager Integration", .tags(.integration))
struct VMManagerIntegrationTests {
    // MARK: - PID File Roundtrip

    @Test("PID file write then readPID returns matching value")
    func pidFileRoundtrip() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let pidFile = tempDir.appendingPathComponent("vm.pid")
        let expectedPID: pid_t = 42
        try "\(expectedPID)".write(to: pidFile, atomically: true, encoding: .utf8)

        let readBack = VMManager.readPID(from: pidFile)
        #expect(readBack == expectedPID)
    }

    @Test("readPID returns nil after PID file is removed")
    func pidFileRemoval() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let pidFile = tempDir.appendingPathComponent("vm.pid")
        try "12345".write(to: pidFile, atomically: true, encoding: .utf8)

        let before = VMManager.readPID(from: pidFile)
        #expect(before == 12345)

        try FileManager.default.removeItem(at: pidFile)

        let after = VMManager.readPID(from: pidFile)
        #expect(after == nil)
    }
}
