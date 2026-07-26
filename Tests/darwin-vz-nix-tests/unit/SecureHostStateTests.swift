import Darwin
@testable import DarwinVZNixLib
import Foundation
import Testing

struct SecureHostStateTests {
    private struct InjectedWriteFailure: Error {}

    @Test
    func canonicalizesOnlyFixedMacOSSystemAliases() {
        #expect(SecureHostState.canonicalSystemAliasPath("/var/lib/darwin-vz-nix") == "/private/var/lib/darwin-vz-nix")
        #expect(SecureHostState.canonicalSystemAliasPath("/tmp/state") == "/private/tmp/state")
        #expect(SecureHostState.canonicalSystemAliasPath("/etc") == "/private/etc")
        #expect(SecureHostState.canonicalSystemAliasPath("/Users/alice/state") == "/Users/alice/state")
    }

    @Test
    func rejectsAncestorSymlinkWithoutTouchingTarget() throws {
        let base = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: base) }
        let realParent = base.appendingPathComponent("real", isDirectory: true)
        let stateDirectory = realParent.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let sentinel = stateDirectory.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realParent)

        #expect(throws: (any Error).self) {
            try SecureHostState.ensureAndValidateStateDirectory(
                link.appendingPathComponent("state", isDirectory: true)
            )
        }
        #expect(try Data(contentsOf: sentinel) == Data("unchanged".utf8))
        #expect(!FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("ssh").path))
    }

    @Test
    func rejectsDirectArtifactSymlinkWithoutTouchingTarget() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }
        let sentinel = stateDirectory.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: stateDirectory.appendingPathComponent("daemon.log"),
            withDestinationURL: sentinel
        )

        #expect(throws: (any Error).self) {
            try SecureHostState.ensureAndValidateStateDirectory(stateDirectory)
        }
        #expect(try Data(contentsOf: sentinel) == Data("unchanged".utf8))
    }

    @Test
    func rejectsGroupWritableStateDirectory() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }
        #expect(chmod(stateDirectory.path, 0o775) == 0)

        #expect(throws: (any Error).self) {
            try SecureHostState.ensureAndValidateStateDirectory(stateDirectory)
        }
    }

    @Test
    func rejectsWritableAncestorWithoutTouchingState() throws {
        let base = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: base) }
        let writableParent = base.appendingPathComponent("writable", isDirectory: true)
        let stateDirectory = writableParent.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let sentinel = stateDirectory.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        #expect(chmod(writableParent.path, 0o770) == 0)

        #expect(throws: (any Error).self) {
            try SecureHostState.ensureAndValidateStateDirectory(stateDirectory)
        }
        #expect(try Data(contentsOf: sentinel) == Data("unchanged".utf8))
        #expect(!FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("ssh").path))
    }

    @Test(arguments: ["write", "delete", "add_file", "add_subdirectory"])
    func rejectsNonOwnerMutatingAllowACL(_ permission: String) throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }
        try addACL("everyone allow \(permission)", to: stateDirectory)

        #expect(throws: (any Error).self) {
            try SecureHostState.ensureAndValidateStateDirectory(stateDirectory, create: false)
        }
    }

    @Test
    func permitsDenyOnlyExtendedACL() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }
        try addACL(
            "everyone deny write,delete,add_file,add_subdirectory",
            to: stateDirectory
        )

        try SecureHostState.ensureAndValidateStateDirectory(stateDirectory, create: false)
    }

    @Test
    func rejectsUserSSHDirectorySymlinkWithoutTouchingTarget() throws {
        let base = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: base) }
        let source = try makeSourceKeys(in: base)
        defer { close(source) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let sentinelDirectory = base.appendingPathComponent("sentinel", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: sentinelDirectory, withIntermediateDirectories: false)
        let sentinel = sentinelDirectory.appendingPathComponent("keep")
        try Data("unchanged".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".ssh"),
            withDestinationURL: sentinelDirectory
        )

        #expect(throws: (any Error).self) {
            try SecureHostState.installUserSSHFiles(
                sourceSSHFD: source,
                homePath: home.path,
                userID: getuid(),
                groupID: getgid()
            )
        }
        #expect(try Data(contentsOf: sentinel) == Data("unchanged".utf8))
    }

    @Test
    func rejectsPrivateKeySymlinkWithoutTouchingTarget() throws {
        let base = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: base) }
        let source = try makeSourceKeys(in: base)
        defer { close(source) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let userSSH = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: userSSH, withIntermediateDirectories: true)
        #expect(chmod(userSSH.path, 0o700) == 0)
        let sentinel = base.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: userSSH.appendingPathComponent("darwin-vz-nix"),
            withDestinationURL: sentinel
        )

        #expect(throws: (any Error).self) {
            try SecureHostState.installUserSSHFiles(
                sourceSSHFD: source,
                homePath: home.path,
                userID: getuid(),
                groupID: getgid()
            )
        }
        #expect(try Data(contentsOf: sentinel) == Data("unchanged".utf8))
    }

    @Test
    func rejectsNonOwnerReadAllowACLOnPrivateKey() throws {
        let base = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: base) }
        let source = try makeSourceKeys(in: base)
        defer { close(source) }
        try addACL(
            "everyone allow read",
            to: base.appendingPathComponent("source/id_ed25519")
        )
        let home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)

        #expect(throws: (any Error).self) {
            try SecureHostState.installUserSSHFiles(
                sourceSSHFD: source,
                homePath: home.path,
                userID: getuid(),
                groupID: getgid()
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".ssh/darwin-vz-nix").path
        ))
    }

    @Test
    func forceStopMarkerRemainsAvailableUntilExplicitCleanup() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        _ = try SecureHostState.markIntentionalStop(stateDirectory: stateDirectory, pid: 42)
        #expect(try SecureHostState.validatedIntentionalStopToken(stateDirectory: stateDirectory) != nil)
        #expect(try SecureHostState.validatedIntentionalStopToken(stateDirectory: stateDirectory) != nil)
        #expect(try SecureHostState.hasIntentionalStopMarker(stateDirectory: stateDirectory))
    }

    @Test
    func forceStopMarkerCompletesRenameAndDirectorySyncBeforeSuccess() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }
        var stages: [SecureHostState.DurableWriteStage] = []

        _ = try SecureHostState.markIntentionalStop(
            stateDirectory: stateDirectory,
            pid: 42
        ) { stage in
            stages.append(stage)
        }

        #expect(stages == [.write, .rename, .directorySync])
        #expect(try SecureHostState.hasIntentionalStopMarker(stateDirectory: stateDirectory))
    }

    @Test
    func forceStopMarkerDirectorySyncFailurePublishesNoProtocolState() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }
        let staleToken = SecureHostState.IntentionalStopToken(
            pid: 41,
            createdAtSeconds: 1000,
            nonce: "stale"
        )
        try SecureHostState.acknowledgeIntentionalStop(
            stateDirectory: stateDirectory,
            token: staleToken
        )

        #expect(throws: InjectedWriteFailure.self) {
            try SecureHostState.markIntentionalStop(
                stateDirectory: stateDirectory,
                pid: 42
            ) { stage in
                if stage == .directorySync { throw InjectedWriteFailure() }
            }
        }

        #expect(try !SecureHostState.hasIntentionalStopMarker(stateDirectory: stateDirectory))
        #expect(try !SecureHostState.hasIntentionalStopAcknowledgement(
            stateDirectory: stateDirectory,
            expectedToken: staleToken
        ))
    }

    @Test
    func rejectsNonOwnerMutatingAllowACLOnIntentionalStopMarker() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }
        _ = try SecureHostState.markIntentionalStop(stateDirectory: stateDirectory, pid: 42)
        try addACL(
            "everyone allow write",
            to: stateDirectory.appendingPathComponent(".intentional-stop")
        )

        #expect(throws: (any Error).self) {
            try SecureHostState.validatedIntentionalStopToken(stateDirectory: stateDirectory)
        }
    }

    @Test
    func launchdRestartDurablyAcknowledgesForceStopMarker() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let expectedToken = try SecureHostState.markIntentionalStop(
            stateDirectory: stateDirectory,
            pid: 42
        )
        let consumed = try SecureHostState.validatedIntentionalStopToken(stateDirectory: stateDirectory)
        let consumedToken = try #require(consumed)
        try SecureHostState.acknowledgeIntentionalStop(
            stateDirectory: stateDirectory,
            token: consumedToken
        )

        #expect(try SecureHostState.hasIntentionalStopAcknowledgement(
            stateDirectory: stateDirectory,
            expectedToken: expectedToken
        ))
        #expect(try SecureHostState.waitForIntentionalStopAcknowledgement(
            stateDirectory: stateDirectory,
            expectedToken: expectedToken,
            timeout: 0
        ))
        #expect(try SecureHostState.hasIntentionalStopMarker(stateDirectory: stateDirectory))
    }

    @Test
    func newForceStopMarkerClearsStaleAcknowledgement() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let staleToken = SecureHostState.IntentionalStopToken(
            pid: 41,
            createdAtSeconds: 1000,
            nonce: "stale"
        )
        try SecureHostState.acknowledgeIntentionalStop(
            stateDirectory: stateDirectory,
            token: staleToken
        )
        let currentToken = try SecureHostState.markIntentionalStop(
            stateDirectory: stateDirectory,
            pid: 42
        )

        #expect(try !SecureHostState.hasIntentionalStopAcknowledgement(
            stateDirectory: stateDirectory,
            expectedToken: currentToken
        ))
        #expect(try SecureHostState.hasIntentionalStopMarker(stateDirectory: stateDirectory))
    }

    @Test
    func mismatchedAcknowledgementDoesNotSatisfyWait() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let expectedToken = try SecureHostState.markIntentionalStop(
            stateDirectory: stateDirectory,
            pid: 42,
            nonce: "expected"
        )
        let mismatchedToken = SecureHostState.IntentionalStopToken(
            pid: expectedToken.pid,
            createdAtSeconds: expectedToken.createdAtSeconds,
            nonce: "different-generation"
        )
        try SecureHostState.acknowledgeIntentionalStop(
            stateDirectory: stateDirectory,
            token: mismatchedToken
        )

        #expect(try !SecureHostState.waitForIntentionalStopAcknowledgement(
            stateDirectory: stateDirectory,
            expectedToken: expectedToken,
            timeout: 0
        ))
    }

    @Test
    func markerReadWithoutAcknowledgementRemainsRestartSuppressing() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let expectedToken = try SecureHostState.markIntentionalStop(
            stateDirectory: stateDirectory,
            pid: 42
        )
        let consumed = try SecureHostState.validatedIntentionalStopToken(stateDirectory: stateDirectory)
        let consumedToken = try #require(consumed)
        #expect(consumedToken == expectedToken)
        #expect(try SecureHostState.hasIntentionalStopMarker(stateDirectory: stateDirectory))
        #expect(try !SecureHostState.waitForIntentionalStopAcknowledgement(
            stateDirectory: stateDirectory,
            expectedToken: expectedToken,
            timeout: 0
        ))
    }

    @Test
    func acknowledgementFailuresPreserveMarkerAndPublishNoAcknowledgement() throws {
        for failedStage in [
            SecureHostState.DurableWriteStage.write,
            .rename,
            .directorySync,
        ] {
            let stateDirectory = makeTempDirectory()
            defer { TestHelpers.removeTempItem(at: stateDirectory) }
            let token = try SecureHostState.markIntentionalStop(
                stateDirectory: stateDirectory,
                pid: 42,
                nonce: "failure-\(failedStage)"
            )

            #expect(throws: InjectedWriteFailure.self) {
                try SecureHostState.acknowledgeIntentionalStop(
                    stateDirectory: stateDirectory,
                    token: token
                ) { stage in
                    if stage == failedStage { throw InjectedWriteFailure() }
                }
            }

            #expect(try SecureHostState.hasIntentionalStopMarker(stateDirectory: stateDirectory))
            #expect(try !SecureHostState.hasIntentionalStopAcknowledgement(
                stateDirectory: stateDirectory,
                expectedToken: token
            ))
            #expect(try SecureHostState.validatedIntentionalStopToken(
                stateDirectory: stateDirectory
            ) == token)
        }
    }

    @Test
    func acknowledgementCompletesRenameAndDirectorySyncBeforeSuccess() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }
        let token = try SecureHostState.markIntentionalStop(stateDirectory: stateDirectory, pid: 42)
        var stages: [SecureHostState.DurableWriteStage] = []

        try SecureHostState.acknowledgeIntentionalStop(
            stateDirectory: stateDirectory,
            token: token
        ) { stage in
            stages.append(stage)
        }

        #expect(stages == [.write, .rename, .directorySync])
        #expect(try SecureHostState.hasIntentionalStopAcknowledgement(
            stateDirectory: stateDirectory,
            expectedToken: token
        ))
        #expect(try SecureHostState.hasIntentionalStopMarker(stateDirectory: stateDirectory))
    }

    @Test
    func intentionalStopMarkerDoesNotExpire() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }
        let createdAt = Date(timeIntervalSince1970: 1000)
        _ = try SecureHostState.markIntentionalStop(
            stateDirectory: stateDirectory,
            pid: 42,
            now: createdAt
        )

        #expect(try SecureHostState.validatedIntentionalStopToken(
            stateDirectory: stateDirectory,
            now: createdAt.addingTimeInterval(31_536_000)
        ) != nil)
        #expect(try SecureHostState.hasIntentionalStopMarker(stateDirectory: stateDirectory))
    }

    @Test
    func acknowledgementTimeoutPreservesForceStopMarker() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        let expectedToken = try SecureHostState.markIntentionalStop(
            stateDirectory: stateDirectory,
            pid: 42
        )

        #expect(try !SecureHostState.waitForIntentionalStopAcknowledgement(
            stateDirectory: stateDirectory,
            expectedToken: expectedToken,
            timeout: 0
        ))
        #expect(try SecureHostState.hasIntentionalStopMarker(stateDirectory: stateDirectory))
    }

    @Test
    func rejectsOversizedIntentionalStopMarker() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }
        try SecureHostState.ensureAndValidateStateDirectory(stateDirectory)
        let marker = stateDirectory.appendingPathComponent(".intentional-stop")
        try Data(
            repeating: 0x41,
            count: SecureHostState.intentionalStopTokenMaximumBytes + 1
        ).write(to: marker)
        #expect(chmod(marker.path, 0o600) == 0)

        #expect(throws: (any Error).self) {
            try SecureHostState.validatedIntentionalStopToken(stateDirectory: stateDirectory)
        }
    }

    @Test
    func rejectsAcknowledgementSymlinkWithoutTouchingTarget() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }
        let sentinel = stateDirectory.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: stateDirectory.appendingPathComponent(".intentional-stop-ack"),
            withDestinationURL: sentinel
        )

        #expect(throws: (any Error).self) {
            try SecureHostState.hasIntentionalStopAcknowledgement(
                stateDirectory: stateDirectory,
                expectedToken: SecureHostState.IntentionalStopToken(
                    pid: 42,
                    createdAtSeconds: 1000,
                    nonce: "expected"
                )
            )
        }
        #expect(try Data(contentsOf: sentinel) == Data("unchanged".utf8))
    }

    @Test
    func normalStopClearsMarkerBeforeLaunchdCanConsumeIt() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        _ = try SecureHostState.markIntentionalStop(stateDirectory: stateDirectory, pid: 42)
        try SecureHostState.clearIntentionalStop(stateDirectory: stateDirectory)
        #expect(try SecureHostState.validatedIntentionalStopToken(stateDirectory: stateDirectory) == nil)
    }

    @Test
    func manualStartClearsForceStopMarker() throws {
        let stateDirectory = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: stateDirectory) }

        _ = try SecureHostState.markIntentionalStop(stateDirectory: stateDirectory, pid: 42)
        try SecureHostState.clearIntentionalStop(stateDirectory: stateDirectory)
        #expect(try SecureHostState.validatedIntentionalStopToken(stateDirectory: stateDirectory) == nil)
    }

    @Test(arguments: [nil, "", "root", "loginwindow"] as [String?])
    func skipsSSHInstallationWithoutAnInteractiveConsoleUser(_ consoleUser: String?) {
        #expect(!SecureHostState.shouldInstallUserSSHFiles(consoleUser: consoleUser))
    }

    @Test
    func installsSSHFilesForInteractiveConsoleUser() {
        #expect(SecureHostState.shouldInstallUserSSHFiles(consoleUser: "alice"))
    }

    @Test
    func repairsMismatchedPublicKeyWithoutReplacingPrivateKey() throws {
        let base = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: base) }
        let source = try makeGeneratedSourceKeys(in: base)
        defer { close(source) }
        let privateURL = base.appendingPathComponent("source/id_ed25519")
        let publicURL = base.appendingPathComponent("source/id_ed25519.pub")
        let originalPrivate = try Data(contentsOf: privateURL)
        try Data("ssh-ed25519 mismatched test\n".utf8).write(to: publicURL)

        try SecureHostState.ensureHostKeyPair(
            sshFD: source,
            keyGenerationRootPath: base.path,
            keyGenerationOwner: getuid()
        )

        #expect(try Data(contentsOf: privateURL) == originalPrivate)
        #expect(try Data(contentsOf: publicURL) != Data("ssh-ed25519 mismatched test\n".utf8))
    }

    @Test
    func failedPublicRepairPreservesPrivateAndCanBeRetried() throws {
        let base = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: base) }
        let source = try makeGeneratedSourceKeys(in: base)
        defer { close(source) }
        let privateURL = base.appendingPathComponent("source/id_ed25519")
        let publicURL = base.appendingPathComponent("source/id_ed25519.pub")
        let sentinel = base.appendingPathComponent("sentinel")
        let originalPrivate = try Data(contentsOf: privateURL)
        try FileManager.default.removeItem(at: publicURL)
        try Data("unchanged".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: publicURL, withDestinationURL: sentinel)

        #expect(throws: (any Error).self) {
            try SecureHostState.ensureHostKeyPair(
                sshFD: source,
                keyGenerationRootPath: base.path,
                keyGenerationOwner: getuid()
            )
        }
        #expect(try Data(contentsOf: privateURL) == originalPrivate)
        #expect(try Data(contentsOf: sentinel) == Data("unchanged".utf8))

        try FileManager.default.removeItem(at: publicURL)
        try SecureHostState.ensureHostKeyPair(
            sshFD: source,
            keyGenerationRootPath: base.path,
            keyGenerationOwner: getuid()
        )
        #expect(try Data(contentsOf: privateURL) == originalPrivate)
        #expect(FileManager.default.fileExists(atPath: publicURL.path))
    }

    @Test(arguments: [false, true])
    func rejectsOversizedSSHKeySource(_ publicKeyIsOversized: Bool) throws {
        let base = makeTempDirectory()
        defer { TestHelpers.removeTempItem(at: base) }
        let sourceDirectory = base.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: false
        )
        #expect(chmod(sourceDirectory.path, 0o700) == 0)
        let privateKey = sourceDirectory.appendingPathComponent("id_ed25519")
        let publicKey = sourceDirectory.appendingPathComponent("id_ed25519.pub")
        try Data(
            repeating: 0x41,
            count: publicKeyIsOversized ? 7 : SecureHostState.privateKeyMaximumBytes + 1
        ).write(to: privateKey)
        try Data(
            repeating: 0x42,
            count: publicKeyIsOversized ? SecureHostState.publicKeyMaximumBytes + 1 : 6
        ).write(to: publicKey)
        #expect(chmod(privateKey.path, 0o600) == 0)
        #expect(chmod(publicKey.path, 0o644) == 0)
        let sourceFD = open(
            sourceDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceFD >= 0 else {
            throw SecureHostStateError.systemCall("open oversized key source", errno)
        }
        defer { close(sourceFD) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)

        #expect(throws: (any Error).self) {
            try SecureHostState.installUserSSHFiles(
                sourceSSHFD: sourceFD,
                homePath: home.path,
                userID: getuid(),
                groupID: getgid()
            )
        }
    }

    private func makeSourceKeys(in base: URL) throws -> Int32 {
        let source = base.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        #expect(chmod(source.path, 0o700) == 0)
        try Data("private".utf8).write(to: source.appendingPathComponent("id_ed25519"))
        try Data("public".utf8).write(to: source.appendingPathComponent("id_ed25519.pub"))
        let fd = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw SecureHostStateError.systemCall("open test source", errno)
        }
        return fd
    }

    private func addACL(_ specification: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", specification, url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw SecureHostStateError.invalid(
                "chmod +a failed with status \(process.terminationStatus): \(specification)"
            )
        }
    }

    private func makeTempDirectory() -> URL {
        TestHelpers.createTempDirectory().resolvingSymlinksInPath()
    }

    private func makeGeneratedSourceKeys(in base: URL) throws -> Int32 {
        let source = base.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        #expect(chmod(source.path, 0o700) == 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = [
            "-q", "-f", source.appendingPathComponent("id_ed25519").path,
            "-t", "ed25519", "-N", "", "-C", "test",
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let fd = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw SecureHostStateError.systemCall("open generated test source", errno)
        }
        return fd
    }
}
