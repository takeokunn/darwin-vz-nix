@testable import darwin_vz_nix
import Foundation
import Testing

@Suite("VMManager", .tags(.unit))
struct VMManagerTests {
    // MARK: - readPID Tests

    @Test("readPID returns correct value from valid PID file")
    func readPIDValid() {
        let url = TestHelpers.createTempFile(content: "12345\n")
        defer { TestHelpers.removeTempItem(at: url) }
        let pid = VMManager.readPID(from: url)
        #expect(pid == 12345)
    }

    @Test("readPID returns nil for empty file")
    func readPIDEmptyFile() {
        let url = TestHelpers.createTempFile(content: "")
        defer { TestHelpers.removeTempItem(at: url) }
        let pid = VMManager.readPID(from: url)
        #expect(pid == nil)
    }

    @Test("readPID returns nil for non-existent file")
    func readPIDNonExistent() {
        let url = URL(fileURLWithPath: "/tmp/nonexistent-pid-\(UUID().uuidString)")
        let pid = VMManager.readPID(from: url)
        #expect(pid == nil)
    }

    @Test("readPID returns nil for file with non-numeric content")
    func readPIDNonNumeric() {
        let url = TestHelpers.createTempFile(content: "abc")
        defer { TestHelpers.removeTempItem(at: url) }
        let pid = VMManager.readPID(from: url)
        #expect(pid == nil)
    }

    // MARK: - isProcessRunning Tests

    @Test("isProcessRunning returns true for current process PID")
    func isProcessRunningCurrentProcess() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        #expect(VMManager.isProcessRunning(pid: currentPID) == true)
    }

    @Test("isProcessRunning returns false for invalid PID")
    func isProcessRunningInvalidPID() {
        #expect(VMManager.isProcessRunning(pid: 99999) == false)
    }

    // MARK: - VMManagerError Tests

    @Test("VMManagerError.errorDescription is non-nil and contains expected keywords for all cases")
    func errorDescriptions() throws {
        let cases: [(VMManagerError, String)] = [
            (.vmNotRunning, "no virtual machine"),
            (.vmAlreadyRunning, "already"),
            (.diskImageCreationFailed("test reason"), "disk"),
            (.pidFileWriteFailed("test reason"), "PID"),
            (.startFailed("test reason"), "start"),
            (.stopFailed("test reason"), "stop"),
            (.configurationInvalid("test reason"), "configuration"),
        ]
        for (error, keyword) in cases {
            let description = error.errorDescription
            #expect(description != nil)
            #expect(try #require(description?.localizedLowercase.contains(keyword.lowercased())))
        }
    }
}
