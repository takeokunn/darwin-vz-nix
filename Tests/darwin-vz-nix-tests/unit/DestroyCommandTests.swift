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

    /// While a VM holds the exclusive state-directory flock — e.g. a `start`
    /// that is still booting and has not written vm.pid yet, or a running VM
    /// whose PID file was corrupted or hand-deleted — `destroy` must refuse to
    /// delete state (disk.img is open read-write in that process).
    @Test
    func destroyRefusesWhileStateLockIsHeld() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let disk = stateDirectory.appendingPathComponent("disk.img")
        try Data("disk".utf8).write(to: disk)

        let lockFD = Start.tryLockStateDirectory(stateDirectory)
        #expect(lockFD >= 0)
        defer { close(lockFD) }

        var cmd = try Destroy.parse(["--yes", "--state-dir", stateDirectory.path])
        await #expect(throws: ExitCode(ExitStatus.operational)) {
            try await cmd.run()
        }

        // Nothing may have been deleted.
        #expect(FileManager.default.fileExists(atPath: disk.path))
    }

    /// A missing state directory is not an error — and `destroy` must not
    /// recreate it as a side effect (the flock guard creates vm.lock, which
    /// would otherwise resurrect the directory).
    @Test
    func destroyOnMissingStateDirectorySucceeds() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        TestHelpers.removeTempItem(at: stateDirectory)

        var cmd = try Destroy.parse(["--yes", "--state-dir", stateDirectory.path])
        try await cmd.run()

        #expect(!FileManager.default.fileExists(atPath: stateDirectory.path))
    }

    /// `destroy --yes` removes the (now empty) state directory itself.
    @Test
    func destroyRemovesEmptiedStateDirectory() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        try Data("disk".utf8).write(to: stateDirectory.appendingPathComponent("disk.img"))

        var cmd = try Destroy.parse(["--yes", "--state-dir", stateDirectory.path])
        try await cmd.run()

        #expect(!FileManager.default.fileExists(atPath: stateDirectory.path))
    }

    @Test
    func destroyCleansCorruptedIntentionalStopState() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }
        try Data("not-json".utf8).write(
            to: stateDirectory.appendingPathComponent(
                SecureHostState.intentionalStopMarkerName
            )
        )
        let staleAcknowledgement = SecureHostState.IntentionalStopToken(
            pid: 999,
            createdAtSeconds: 1,
            nonce: "stale"
        )
        try SecureHostState.acknowledgeIntentionalStop(
            stateDirectory: stateDirectory,
            token: staleAcknowledgement
        )

        var cmd = try Destroy.parse(["--yes", "--state-dir", stateDirectory.path])
        try await cmd.run()

        #expect(!FileManager.default.fileExists(atPath: stateDirectory.path))
    }

    @Test
    func destroyRejectsOldUnacknowledgedIntentionalStop() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }
        _ = try SecureHostState.markIntentionalStop(
            stateDirectory: stateDirectory,
            pid: 42,
            now: Date(timeIntervalSince1970: 1)
        )

        var cmd = try Destroy.parse(["--yes", "--state-dir", stateDirectory.path])
        await #expect(throws: ExitCode(ExitStatus.operational)) {
            try await cmd.run()
        }

        #expect(FileManager.default.fileExists(atPath: stateDirectory.path))
    }

    @Test
    func destroyRejectsLiveUnacknowledgedIntentionalStop() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }
        _ = try SecureHostState.markIntentionalStop(stateDirectory: stateDirectory, pid: 42)

        var cmd = try Destroy.parse(["--yes", "--state-dir", stateDirectory.path])
        await #expect(throws: ExitCode(ExitStatus.operational)) {
            try await cmd.run()
        }

        #expect(try SecureHostState.hasIntentionalStopMarker(stateDirectory: stateDirectory))
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
        try FileManager.default.createSymbolicLink(
            atPath: gcroots.appendingPathComponent("kernel").path,
            withDestinationPath: "/nix/store/test-kernel"
        )
        try Data("ssh-ed25519 AAAA builder@darwin-vz-nix".utf8)
            .write(to: sshPub.appendingPathComponent("id_ed25519.pub"))

        var cmd = try Destroy.parse(["--yes", "--state-dir", stateDirectory.path])
        try await cmd.run()

        #expect(FileManager.default.fileExists(atPath: gcroots.path) == false)
        #expect(FileManager.default.fileExists(atPath: sshPub.path) == false)
    }

    @Test
    func destroyPreservesUnrelatedDirectoryContentsAndSameNameWrongType() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let ssh = stateDirectory.appendingPathComponent("ssh", isDirectory: true)
        let sshPub = stateDirectory.appendingPathComponent("ssh-pub", isDirectory: true)
        let gcroots = stateDirectory.appendingPathComponent("gcroots", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sshPub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gcroots, withIntermediateDirectories: true)

        let sshNote = ssh.appendingPathComponent("keep.txt")
        let publicNote = sshPub.appendingPathComponent("keep.txt")
        let unrelatedKernel = gcroots.appendingPathComponent("kernel")
        try Data("unrelated".utf8).write(to: sshNote)
        try Data("unrelated".utf8).write(to: publicNote)
        try Data("not a GC root".utf8).write(to: unrelatedKernel)

        var cmd = try Destroy.parse(["--yes", "--state-dir", stateDirectory.path])
        try await cmd.run()

        #expect(try String(contentsOf: sshNote, encoding: .utf8) == "unrelated")
        #expect(try String(contentsOf: publicNote, encoding: .utf8) == "unrelated")
        #expect(try String(contentsOf: unrelatedKernel, encoding: .utf8) == "not a GC root")
        #expect(
            Destroy.completionMessage(
                for: .preservedUnknownContents,
                stateDirectory: stateDirectory
            )
                == "Known VM state was destroyed, but \(stateDirectory.path) was preserved because it contains unrelated files."
        )
    }

    @Test
    func destroyRejectsSymlinkedArtifactDirectory() async throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        let outsideDirectory = TestHelpers.createTempDirectory()
        defer {
            TestHelpers.removeTempItem(at: stateDirectory)
            TestHelpers.removeTempItem(at: outsideDirectory)
        }

        let outsideKey = outsideDirectory.appendingPathComponent("id_ed25519")
        try Data("outside".utf8).write(to: outsideKey)
        try FileManager.default.createSymbolicLink(
            atPath: stateDirectory.appendingPathComponent("ssh").path,
            withDestinationPath: outsideDirectory.path
        )

        var cmd = try Destroy.parse(["--yes", "--state-dir", stateDirectory.path])
        await #expect(throws: SecureHostStateError.self) {
            try await cmd.run()
        }

        #expect(try String(contentsOf: outsideKey, encoding: .utf8) == "outside")
        var info = stat()
        #expect(lstat(stateDirectory.appendingPathComponent("ssh").path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFLNK)
    }

    @Test
    func descriptorRelativeDeletionPreservesReplacementRaceWinner() throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let ssh = stateDirectory.appendingPathComponent("ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let key = ssh.appendingPathComponent("id_ed25519")
        let displaced = ssh.appendingPathComponent("displaced-key")
        try Data("original".utf8).write(to: key)

        try Destroy.deleteKnownArtifacts(in: stateDirectory) { logicalPath in
            guard logicalPath == "ssh/id_ed25519" else { return }
            try FileManager.default.moveItem(at: key, to: displaced)
            try Data("replacement".utf8).write(to: key)
        }

        #expect(try String(contentsOf: key, encoding: .utf8) == "replacement")
        #expect(try String(contentsOf: displaced, encoding: .utf8) == "original")
    }

    @Test
    func destroyHandleRejectsReplacedStateDirectory() throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        let displacedDirectory = stateDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("\(stateDirectory.lastPathComponent)-displaced")
        defer {
            TestHelpers.removeTempItem(at: stateDirectory)
            TestHelpers.removeTempItem(at: displacedDirectory)
        }

        let originalDisk = stateDirectory.appendingPathComponent("disk.img")
        try Data("original".utf8).write(to: originalDisk)
        let lockedState = try SecureHostState.openAndLockStateDirectoryForDestruction(
            stateDirectory
        )

        try FileManager.default.moveItem(at: stateDirectory, to: displacedDirectory)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: false)
        let replacementDisk = stateDirectory.appendingPathComponent("disk.img")
        try Data("replacement".utf8).write(to: replacementDisk)

        #expect(throws: SecureHostStateError.self) {
            try Destroy.deleteKnownArtifacts(in: lockedState)
        }
        #expect(try String(contentsOf: replacementDisk, encoding: .utf8) == "replacement")
        #expect(
            try String(
                contentsOf: displacedDirectory.appendingPathComponent("disk.img"),
                encoding: .utf8
            ) == "original"
        )
    }

    @Test
    func destroyKeepsOldLockLinkedUntilStateNameIsTombstoned() throws {
        let stateDirectory = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let lockedState = try SecureHostState.openAndLockStateDirectoryForDestruction(
            stateDirectory
        )
        var oldLockInfo = stat()
        #expect(fstat(lockedState.lockFD, &oldLockInfo) == 0)

        var newLockFD: Int32 = -1
        let result = try Destroy.finalizeStateDirectory(lockedState) {
            #expect(!FileManager.default.fileExists(atPath: stateDirectory.path))
            try SecureHostState.ensureAndValidateStateDirectory(stateDirectory)
            newLockFD = Start.tryLockStateDirectory(stateDirectory)
            #expect(newLockFD >= 0)
        }
        defer {
            if newLockFD >= 0 { close(newLockFD) }
        }

        var newLockInfo = stat()
        #expect(fstat(newLockFD, &newLockInfo) == 0)
        #expect(oldLockInfo.st_dev != newLockInfo.st_dev || oldLockInfo.st_ino != newLockInfo.st_ino)
        #expect(result == .removed)
        #expect(FileManager.default.fileExists(atPath: stateDirectory.path))
    }
}
