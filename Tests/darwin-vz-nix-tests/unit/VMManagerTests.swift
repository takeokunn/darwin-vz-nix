@testable import DarwinVZNixLib
import Foundation
import Testing

@Suite("VMManager", .tags(.unit))
struct VMManagerTests {
    private enum SampleError: Error {
        case failed
    }

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

    @Test("guestIPFileURL points to expected location")
    func guestIPFileLocation() {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let kernel = stateDirectory.appendingPathComponent("Image")
        let initrd = stateDirectory.appendingPathComponent("initrd")
        FileManager.default.createFile(atPath: kernel.path, contents: Data("kernel".utf8))
        FileManager.default.createFile(atPath: initrd.path, contents: Data("initrd".utf8))

        let config = VMConfig(
            kernelURL: kernel,
            initrdURL: initrd,
            stateDirectory: stateDirectory
        )

        let guestIPFile = config.guestIPFileURL
        #expect(guestIPFile.lastPathComponent == "guest-ip")
        #expect(guestIPFile.deletingLastPathComponent().path == stateDirectory.path)
    }

    @Test("withPIDFile removes stale PID file when startup work fails")
    func withPIDFileCleansUpOnFailure() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let kernel = stateDirectory.appendingPathComponent("Image")
        let initrd = stateDirectory.appendingPathComponent("initrd")
        FileManager.default.createFile(atPath: kernel.path, contents: Data("kernel".utf8))
        FileManager.default.createFile(atPath: initrd.path, contents: Data("initrd".utf8))

        let config = VMConfig(
            kernelURL: kernel,
            initrdURL: initrd,
            stateDirectory: stateDirectory
        )
        let manager = VMManager(config: config)

        await #expect(throws: SampleError.self) {
            try await manager.withPIDFile {
                throw SampleError.failed
            }
        }

        #expect(FileManager.default.fileExists(atPath: config.pidFileURL.path) == false)
    }

    // MARK: - stripTerminalRequests

    @Test("stripTerminalRequests removes DSR sequences")
    func stripDSR() {
        let input = Data("hello\u{1B}[6n world".utf8)
        let output = VMManager.stripTerminalRequests(input)
        #expect(String(data: output, encoding: .utf8) == "hello world")
    }

    @Test("stripTerminalRequests removes DA (device attributes) sequences")
    func stripDA() {
        let input = Data("before\u{1B}[cafter".utf8)
        let output = VMManager.stripTerminalRequests(input)
        #expect(String(data: output, encoding: .utf8) == "beforeafter")
    }

    @Test("stripTerminalRequests removes parameterized DSR requests like CPR")
    func stripParameterizedDSR() {
        let input = Data("pre\u{1B}[12;34npost".utf8)
        let output = VMManager.stripTerminalRequests(input)
        #expect(String(data: output, encoding: .utf8) == "prepost")
    }

    @Test("stripTerminalRequests preserves color/SGR escape sequences")
    func stripPreservesColor() {
        let input = Data("\u{1B}[31mred\u{1B}[0m".utf8)
        let output = VMManager.stripTerminalRequests(input)
        // Color SGR ends with 'm', not 'n' or 'c', so it must be preserved
        #expect(String(data: output, encoding: .utf8) == "\u{1B}[31mred\u{1B}[0m")
    }

    @Test("stripTerminalRequests returns empty data for empty input")
    func stripEmpty() {
        let output = VMManager.stripTerminalRequests(Data())
        #expect(output.isEmpty)
    }

    @Test("stripTerminalRequests passes plain ASCII text through unchanged")
    func stripPlainText() {
        let input = Data("plain ASCII line\n".utf8)
        let output = VMManager.stripTerminalRequests(input)
        #expect(output == input)
    }

    @Test("stripTerminalRequests handles multiple DSR sequences in one buffer")
    func stripMultipleSequences() {
        let input = Data("a\u{1B}[6nb\u{1B}[cc".utf8)
        let output = VMManager.stripTerminalRequests(input)
        #expect(String(data: output, encoding: .utf8) == "abc")
    }

    // MARK: - terminateProcess (against real short-lived subprocess)

    @Test("terminateProcess SIGTERM stops a cooperating sleep subprocess and removes pid file")
    func terminateSleepSIGTERM() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }
        let pidFile = tempDir.appendingPathComponent("vm.pid")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["120"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try "\(process.processIdentifier)".write(to: pidFile, atomically: true, encoding: .utf8)

        defer {
            if process.isRunning { process.terminate() }
        }

        let stopped = try VMManager.terminateProcess(pid: process.processIdentifier, pidFileURL: pidFile)
        #expect(stopped == true)
        #expect(FileManager.default.fileExists(atPath: pidFile.path) == false)
        #expect(VMManager.isProcessRunning(pid: process.processIdentifier) == false)
    }

    @Test("terminateProcess force=true kills a sleep subprocess immediately")
    func terminateSleepForceKill() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }
        let pidFile = tempDir.appendingPathComponent("vm.pid")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["120"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try "\(process.processIdentifier)".write(to: pidFile, atomically: true, encoding: .utf8)

        defer {
            if process.isRunning { process.terminate() }
        }

        let stopped = try VMManager.terminateProcess(
            pid: process.processIdentifier, pidFileURL: pidFile, force: true
        )
        #expect(stopped == true)
        #expect(FileManager.default.fileExists(atPath: pidFile.path) == false)
    }

    @Test("terminateProcess throws stopFailed when pid does not exist")
    func terminateNonExistentPID() {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }
        let pidFile = tempDir.appendingPathComponent("vm.pid")

        // PID 99999 is extremely unlikely to exist on a test host.
        // kill(99999, SIGTERM) will return ESRCH, which terminateProcess surfaces as stopFailed.
        #expect(throws: VMManagerError.self) {
            _ = try VMManager.terminateProcess(pid: 99999, pidFileURL: pidFile)
        }
    }
}
