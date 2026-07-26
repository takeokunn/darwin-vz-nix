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
        let directory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: directory) }
        let url = directory.appendingPathComponent("vm.pid")
        let record = VMProcessRecord(
            pid: 12345,
            executablePath: "/nix/store/example/bin/darwin-vz-nix",
            stateDirectory: directory.path,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: url)

        let decoded = try #require(VMManager.readPIDRecord(from: url))
        #expect(decoded == record)
        #expect(VMManager.readPID(from: url) == 12345)
    }

    @Test
    func readPIDJSONDefaultsMissingLaunchdManagedToFalse() throws {
        let url = TestHelpers.createTempFile(content: "")
        defer { TestHelpers.removeTempItem(at: url) }
        let record = VMProcessRecord(
            pid: 12345,
            executablePath: "/nix/store/example/bin/darwin-vz-nix",
            stateDirectory: url.deletingLastPathComponent().path,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any]
        )
        object.removeValue(forKey: "launchdManaged")
        try String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self).write(
            to: url,
            atomically: true,
            encoding: .utf8
        )

        let decoded = try #require(VMManager.readPIDRecord(from: url))
        #expect(decoded.launchdManaged == false)
    }

    @Test
    func readPIDJSONPreservesLaunchdManaged() throws {
        let url = TestHelpers.createTempFile(content: "")
        defer { TestHelpers.removeTempItem(at: url) }
        let record = VMProcessRecord(
            pid: 12345,
            executablePath: "/nix/store/example/bin/darwin-vz-nix",
            stateDirectory: url.deletingLastPathComponent().path,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            launchdManaged: true
        )
        try write(record, to: url)

        #expect(try #require(VMManager.readPIDRecord(from: url)).launchdManaged)
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
        try writeRecord(for: process, stateDirectory: tempDir, to: pidFile)

        defer {
            if process.isRunning { process.terminate() }
        }

        let termination = try VMManager.terminateProcess(
            pid: process.processIdentifier,
            pidFileURL: pidFile
        )
        #expect(termination.stopped == true)
        #expect(termination.usedSIGKILL == false)
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
        try writeRecord(for: process, stateDirectory: tempDir, to: pidFile)

        defer {
            if process.isRunning { process.terminate() }
        }

        let termination = try VMManager.terminateProcess(
            pid: process.processIdentifier, pidFileURL: pidFile, force: true
        )
        #expect(termination.stopped == true)
        #expect(termination.usedSIGKILL == true)
        #expect(FileManager.default.fileExists(atPath: pidFile.path) == false)
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
        let record = VMProcessRecord(
            pid: process.processIdentifier,
            executablePath: "/definitely/not/bin/darwin-vz-nix",
            stateDirectory: tempDir.path,
            startedAt: Date(),
            processStartTimeMicroseconds: VMManager.processStartTimeMicroseconds(for: process.processIdentifier)
        )
        try write(record, to: pidFile)

        defer {
            if process.isRunning { process.terminate() }
        }

        #expect(throws: VMManagerError.self) {
            _ = try VMManager.terminateProcess(
                pid: process.processIdentifier,
                pidFileURL: pidFile
            )
        }
        #expect(process.isRunning == true)
        #expect(FileManager.default.fileExists(atPath: pidFile.path) == false)
    }

    @Test
    func terminateNonExistentPIDForceDoesNotReportSIGKILL() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }
        let pidFile = tempDir.appendingPathComponent("vm.pid")
        try "99999".write(to: pidFile, atomically: true, encoding: .utf8)

        // PID 99999 is extremely unlikely to exist on a test host.
        // A force request must not report SIGKILL when no signal was actually sent.
        let termination = try VMManager.terminateProcess(
            pid: 99999,
            pidFileURL: pidFile,
            force: true
        )
        #expect(termination.stopped == true)
        #expect(termination.usedSIGKILL == false)
        #expect(FileManager.default.fileExists(atPath: pidFile.path) == false)
    }

    @Test
    func terminateNonExistentPIDFromLegacyFile() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }
        let pidFile = tempDir.appendingPathComponent("vm.pid")
        try "99999".write(to: pidFile, atomically: true, encoding: .utf8)

        let termination = try VMManager.terminateProcess(pid: 99999, pidFileURL: pidFile)
        #expect(termination.stopped == true)
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

    @Test
    func readPIDRecordRejectsSameProcessFromDifferentStateDirectory() throws {
        let directory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: directory) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["120"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let record = VMProcessRecord(
            pid: process.processIdentifier,
            executablePath: VMManager.executablePath(for: process.processIdentifier),
            stateDirectory: directory.appendingPathComponent("other").path,
            startedAt: Date(),
            processStartTimeMicroseconds: VMManager.processStartTimeMicroseconds(for: process.processIdentifier)
        )
        let pidFile = directory.appendingPathComponent("vm.pid")
        try write(record, to: pidFile)
        #expect(VMManager.readPIDRecord(from: pidFile) == nil)
        #expect(!VMManager.processMatchesRecord(record, pidFileURL: pidFile))
    }

    @Test
    func processMatchRejectsReusedPIDStartIdentity() throws {
        let directory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: directory) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["120"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let actualStart = try #require(VMManager.processStartTimeMicroseconds(for: process.processIdentifier))
        let record = VMProcessRecord(
            pid: process.processIdentifier,
            executablePath: "/bin/sleep",
            stateDirectory: directory.path,
            startedAt: Date(),
            processStartTimeMicroseconds: actualStart + 1
        )
        let pidFile = directory.appendingPathComponent("vm.pid")
        try write(record, to: pidFile)

        #expect(!VMManager.processMatchesRecord(record, pidFileURL: pidFile))
        #expect(throws: VMManagerError.self) {
            _ = try VMManager.terminateProcess(pid: record.pid, pidFileURL: pidFile)
        }
        #expect(process.isRunning)
    }

    private func writeRecord(for process: Process, stateDirectory: URL, to pidFile: URL) throws {
        let record = VMProcessRecord(
            pid: process.processIdentifier,
            executablePath: VMManager.executablePath(for: process.processIdentifier),
            stateDirectory: VMManager.canonicalPath(stateDirectory),
            startedAt: Date(),
            processStartTimeMicroseconds: VMManager.processStartTimeMicroseconds(for: process.processIdentifier)
        )
        try write(record, to: pidFile)
    }

    private func write(_ record: VMProcessRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url)
    }
}

extension VMManagerTests {
    @Test
    func enclosingStorePathExtractsRoot() {
        #expect(VMManager.enclosingStorePath(of: URL(fileURLWithPath: "/nix/store/abc123-guest-artifacts/system")) == "/nix/store/abc123-guest-artifacts")
        #expect(VMManager.enclosingStorePath(of: URL(fileURLWithPath: "/nix/store/abc123-guest-artifacts")) == "/nix/store/abc123-guest-artifacts")
        #expect(VMManager.enclosingStorePath(of: URL(fileURLWithPath: "/tmp/not-store")) == nil)
    }

    @Test
    func gcRootWarmStartSkipsNixStore() throws {
        let directory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: directory) }
        let storePath = directory.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: storePath, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("kernel"),
            withDestinationURL: storePath
        )
        try VMManager.ensureGCRoot(
            named: "kernel", storePath: storePath.path, in: directory,
            executableURL: URL(fileURLWithPath: "/definitely/missing")
        )
    }

    @Test
    func gcRootFailureDoesNotAcceptDifferentExistingTarget() throws {
        let directory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: directory) }
        let oldStore = directory.appendingPathComponent("old")
        let newStore = directory.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: oldStore, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newStore, withIntermediateDirectories: true)
        let root = directory.appendingPathComponent("kernel")
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: oldStore)

        #expect(throws: VMManagerError.self) {
            try VMManager.ensureGCRoot(
                named: "kernel", storePath: newStore.path, in: directory,
                executableURL: URL(fileURLWithPath: "/usr/bin/false"), argumentPrefix: []
            )
        }
        #expect(VMManager.canonicalPath(root) == VMManager.canonicalPath(oldStore))
    }

    @Test
    func gcRootFailureWithoutExistingRootThrows() throws {
        let directory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: directory) }
        let storePath = directory.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: storePath, withIntermediateDirectories: true)
        #expect(throws: VMManagerError.self) {
            try VMManager.ensureGCRoot(
                named: "kernel", storePath: storePath.path, in: directory,
                executableURL: URL(fileURLWithPath: "/usr/bin/false"), argumentPrefix: []
            )
        }
    }

    @Test
    func gcRootFailureRejectsDanglingSymlink() throws {
        let directory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: directory) }
        let storePath = directory.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: storePath, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("kernel"),
            withDestinationURL: directory.appendingPathComponent("missing")
        )

        #expect(throws: VMManagerError.self) {
            try VMManager.ensureGCRoot(
                named: "kernel", storePath: storePath.path, in: directory,
                executableURL: URL(fileURLWithPath: "/usr/bin/false"), argumentPrefix: []
            )
        }
    }

    @Test
    func gcRootFailureRejectsRegularFile() throws {
        let directory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: directory) }
        let storePath = directory.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: storePath, withIntermediateDirectories: true)
        try Data("not a root".utf8).write(to: directory.appendingPathComponent("kernel"))

        #expect(throws: VMManagerError.self) {
            try VMManager.ensureGCRoot(
                named: "kernel", storePath: storePath.path, in: directory,
                executableURL: URL(fileURLWithPath: "/usr/bin/false"), argumentPrefix: []
            )
        }
    }

    @Test
    func gcRootSuccessfulRefreshAtomicallyReplacesOldTarget() throws {
        let directory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: directory) }
        let oldStore = directory.appendingPathComponent("old")
        let newStore = directory.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: oldStore, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newStore, withIntermediateDirectories: true)
        let root = directory.appendingPathComponent("kernel")
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: oldStore)
        let fakeNixStore = try makeExecutableScript(
            in: directory,
            contents: "#!/bin/sh\nln -s \"$4\" \"$2\"\n"
        )

        try VMManager.ensureGCRoot(
            named: "kernel", storePath: newStore.path, in: directory,
            executableURL: fakeNixStore, argumentPrefix: []
        )
        #expect(VMManager.canonicalPath(root) == VMManager.canonicalPath(newStore))
    }

    @Test
    func gcRootTimesOutFakeNixStore() throws {
        let directory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: directory) }
        let storePath = directory.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: storePath, withIntermediateDirectories: true)
        let fakeNixStore = try makeExecutableScript(
            in: directory,
            contents: "#!/bin/sh\nexec sleep 5\n"
        )

        #expect(throws: VMManagerError.self) {
            try VMManager.ensureGCRoot(
                named: "kernel", storePath: storePath.path, in: directory,
                executableURL: fakeNixStore, argumentPrefix: [], timeout: 0.05
            )
        }
    }

    private func makeExecutableScript(in directory: URL, contents: String) throws -> URL {
        let script = directory.appendingPathComponent("fake-nix-store-\(UUID().uuidString)")
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
}
