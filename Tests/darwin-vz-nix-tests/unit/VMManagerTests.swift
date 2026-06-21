@testable import DarwinVZNixLib
import Foundation
import Testing

struct VMManagerTests {
    private enum SampleError: Error {
        case failed
    }

    // MARK: - readPID Tests

    @Test
    func readPIDValid() {
        let url = TestHelpers.createTempFile(content: "12345\n")
        defer { TestHelpers.removeTempItem(at: url) }
        let pid = VMManager.readPID(from: url)
        #expect(pid == 12345)
    }

    @Test
    func readPIDJSON() throws {
        let record = VMProcessRecord(
            pid: 12345,
            executablePath: "/nix/store/example/bin/darwin-vz-nix",
            stateDirectory: "/var/lib/darwin-vz-nix",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let url = TestHelpers.createTempFile(content: String(decoding: data, as: UTF8.self))
        defer { TestHelpers.removeTempItem(at: url) }

        let decoded = try #require(VMManager.readPIDRecord(from: url))
        #expect(decoded == record)
        #expect(VMManager.readPID(from: url) == 12345)
    }

    @Test
    func readPIDEmptyFile() {
        let url = TestHelpers.createTempFile(content: "")
        defer { TestHelpers.removeTempItem(at: url) }
        let pid = VMManager.readPID(from: url)
        #expect(pid == nil)
    }

    @Test
    func readPIDNonExistent() {
        let url = URL(fileURLWithPath: "/tmp/nonexistent-pid-\(UUID().uuidString)")
        let pid = VMManager.readPID(from: url)
        #expect(pid == nil)
    }

    @Test
    func readPIDNonNumeric() {
        let url = TestHelpers.createTempFile(content: "abc")
        defer { TestHelpers.removeTempItem(at: url) }
        let pid = VMManager.readPID(from: url)
        #expect(pid == nil)
    }

    @Test
    func readPIDNonPositiveLegacyValue() {
        for value in ["0", "-1"] {
            let url = TestHelpers.createTempFile(content: value)
            defer { TestHelpers.removeTempItem(at: url) }
            #expect(VMManager.readPID(from: url) == nil)
            #expect(VMManager.readPIDRecord(from: url) == nil)
        }
    }

    @Test
    func readPIDNonPositiveJSONValue() throws {
        for pid in [Int32(0), Int32(-1)] {
            let record = VMProcessRecord(
                pid: pid,
                executablePath: "/nix/store/example/bin/darwin-vz-nix",
                stateDirectory: "/var/lib/darwin-vz-nix",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)
            let url = TestHelpers.createTempFile(content: String(decoding: data, as: UTF8.self))
            defer { TestHelpers.removeTempItem(at: url) }

            #expect(VMManager.readPID(from: url) == nil)
            #expect(VMManager.readPIDRecord(from: url) == nil)
        }
    }

    // MARK: - isProcessRunning Tests

    @Test
    func isProcessRunningCurrentProcess() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        #expect(VMManager.isProcessRunning(pid: currentPID) == true)
    }

    @Test
    func isProcessRunningInvalidPID() {
        #expect(VMManager.isProcessRunning(pid: 99999) == false)
    }

    @Test
    func isProcessRunningNonPositivePID() {
        #expect(VMManager.isProcessRunning(pid: 0) == false)
        #expect(VMManager.isProcessRunning(pid: -1) == false)
    }

    // MARK: - VMManagerError Tests

    @Test
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
            let description = try #require(error.errorDescription)
            #expect(description.localizedLowercase.contains(keyword.lowercased()))
        }
    }

    @Test
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

    @Test
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

    @Test
    func stripDSR() {
        let input = Data("hello\u{1B}[6n world".utf8)
        let output = VMManager.stripTerminalRequests(input)
        #expect(String(data: output, encoding: .utf8) == "hello world")
    }

    @Test
    func stripDA() {
        let input = Data("before\u{1B}[cafter".utf8)
        let output = VMManager.stripTerminalRequests(input)
        #expect(String(data: output, encoding: .utf8) == "beforeafter")
    }

    @Test
    func stripParameterizedDSR() {
        let input = Data("pre\u{1B}[12;34npost".utf8)
        let output = VMManager.stripTerminalRequests(input)
        #expect(String(data: output, encoding: .utf8) == "prepost")
    }

    @Test
    func stripPreservesColor() {
        let input = Data("\u{1B}[31mred\u{1B}[0m".utf8)
        let output = VMManager.stripTerminalRequests(input)
        // Color SGR ends with 'm', not 'n' or 'c', so it must be preserved
        #expect(String(data: output, encoding: .utf8) == "\u{1B}[31mred\u{1B}[0m")
    }

    @Test
    func stripEmpty() {
        let output = VMManager.stripTerminalRequests(Data())
        #expect(output.isEmpty)
    }

    @Test
    func stripPlainText() {
        let input = Data("plain ASCII line\n".utf8)
        let output = VMManager.stripTerminalRequests(input)
        #expect(output == input)
    }

    @Test
    func stripMultipleSequences() {
        let input = Data("a\u{1B}[6nb\u{1B}[cc".utf8)
        let output = VMManager.stripTerminalRequests(input)
        #expect(String(data: output, encoding: .utf8) == "abc")
    }

    // MARK: - terminateProcess (against real short-lived subprocess)

    @Test
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

        let stopped = try VMManager.terminateProcess(
            pid: process.processIdentifier,
            pidFileURL: pidFile,
            expectedExecutablePath: "/bin/sleep"
        )
        #expect(stopped == true)
        #expect(FileManager.default.fileExists(atPath: pidFile.path) == false)
        #expect(VMManager.isProcessRunning(pid: process.processIdentifier) == false)
    }

    @Test
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
            pid: process.processIdentifier, pidFileURL: pidFile, force: true,
            expectedExecutablePath: "/bin/sleep"
        )
        #expect(stopped == true)
        #expect(FileManager.default.fileExists(atPath: pidFile.path) == false)
    }

    /// Legacy PID file (no recorded executable path): a recycled PID belonging to
    /// an unrelated process must NOT be treated as our VM (T2.8 hardening).
    @Test
    func processMatchesRecordRejectsLegacyPidForeignProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["120"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        // No expected path => legacy file. /bin/sleep is not darwin-vz-nix.
        #expect(VMManager.processMatchesRecord(
            pid: process.processIdentifier,
            expectedExecutablePath: nil
        ) == false)
    }

    @Test
    func terminateRefusesExecutableMismatch() throws {
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

        #expect(throws: VMManagerError.self) {
            _ = try VMManager.terminateProcess(
                pid: process.processIdentifier,
                pidFileURL: pidFile,
                expectedExecutablePath: "/definitely/not/bin/darwin-vz-nix"
            )
        }
        #expect(process.isRunning == true)
        #expect(FileManager.default.fileExists(atPath: pidFile.path) == false)
    }

    @Test
    func terminateNonExistentPID() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }
        let pidFile = tempDir.appendingPathComponent("vm.pid")
        try "99999".write(to: pidFile, atomically: true, encoding: .utf8)

        // PID 99999 is extremely unlikely to exist on a test host.
        // kill(99999, SIGTERM) returns ESRCH, which should be treated as already stopped.
        let stopped = try VMManager.terminateProcess(pid: 99999, pidFileURL: pidFile)
        #expect(stopped == true)
        #expect(FileManager.default.fileExists(atPath: pidFile.path) == false)
    }

    @Test
    func terminateNonExistentPIDWithExpectedExecutable() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }
        let pidFile = tempDir.appendingPathComponent("vm.pid")
        try "99999".write(to: pidFile, atomically: true, encoding: .utf8)

        let stopped = try VMManager.terminateProcess(
            pid: 99999,
            pidFileURL: pidFile,
            expectedExecutablePath: "/definitely/not/bin/darwin-vz-nix"
        )
        #expect(stopped == true)
        #expect(FileManager.default.fileExists(atPath: pidFile.path) == false)
    }

    @Test
    func terminateNonPositivePID() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }
        let pidFile = tempDir.appendingPathComponent("vm.pid")
        try "0".write(to: pidFile, atomically: true, encoding: .utf8)

        #expect(throws: VMManagerError.self) {
            _ = try VMManager.terminateProcess(pid: 0, pidFileURL: pidFile)
        }
        #expect(FileManager.default.fileExists(atPath: pidFile.path) == false)
    }
}
