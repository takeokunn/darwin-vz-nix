import Darwin
import Foundation

private typealias DarwinUUID = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

@_silgen_name("mbr_uid_to_uuid")
private func membershipUIDToUUID(_ uid: uid_t, _ uuid: UnsafeMutablePointer<DarwinUUID>) -> Int32

enum SecureHostStateError: LocalizedError {
    case invalid(String)
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .invalid(message):
            message
        case let .systemCall(operation, code):
            "\(operation): \(String(cString: strerror(code)))"
        }
    }
}

/// POSIX-only state preparation used by root activation and launchd lifecycle handling.
enum SecureHostState {
    final class LockedStateDirectory {
        let stateFD: Int32
        let lockFD: Int32
        let parentFD: Int32
        let name: String
        let device: dev_t
        let inode: ino_t

        init(
            stateFD: Int32,
            lockFD: Int32,
            parentFD: Int32,
            name: String,
            device: dev_t,
            inode: ino_t
        ) {
            self.stateFD = stateFD
            self.lockFD = lockFD
            self.parentFD = parentFD
            self.name = name
            self.device = device
            self.inode = inode
        }

        deinit {
            close(lockFD)
            close(stateFD)
            close(parentFD)
        }

        func validateOriginalName() throws {
            var metadata = stat()
            guard fstatat(parentFD, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw SecureHostStateError.systemCall("fstatat \(name)", errno)
            }
            guard metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_dev == device,
                  metadata.st_ino == inode
            else {
                throw SecureHostStateError.invalid(
                    "State directory changed after its lock was acquired: \(name)"
                )
            }
        }
    }

    static let intentionalStopMarkerName = ".intentional-stop"
    static let intentionalStopAcknowledgementName = ".intentional-stop-ack"
    static let intentionalStopTokenMaximumBytes = 4 * 1024
    static let privateKeyMaximumBytes = 64 * 1024
    static let publicKeyMaximumBytes = 16 * 1024

    struct IntentionalStopToken: Codable, Equatable {
        let pid: Int32
        let createdAtSeconds: Int64
        let nonce: String
    }

    enum IntentionalStopMarkerState: Equatable {
        case absent
        case live(IntentionalStopToken)
        case invalid
    }

    private struct IntentionalStopMarkerInspection {
        let state: IntentionalStopMarkerState
        let device: dev_t?
        let inode: ino_t?
    }

    enum DurableWriteStage {
        case write
        case rename
        case directorySync
    }

    private static let regularArtifacts = [
        "disk.img", "vm.pid", "vm.lock", "guest-ip", "console.log", "daemon.log",
        intentionalStopMarkerName, intentionalStopAcknowledgementName,
    ]
    private static let directoryArtifacts = ["ssh", "ssh-pub", "gcroots"]

    static func ensureAndValidateStateDirectory(_ url: URL, create: Bool = true) throws {
        let directoryFD = try openDirectoryPath(
            url.path,
            owner: geteuid(),
            createMissingComponents: create
        )
        defer { close(directoryFD) }

        for name in regularArtifacts {
            try validateChildIfPresent(directoryFD, name: name, kind: S_IFREG, owner: geteuid())
        }
        for name in directoryArtifacts {
            try validateChildIfPresent(directoryFD, name: name, kind: S_IFDIR, owner: geteuid())
        }
    }

    static func prepareHost(stateDirectory: URL, consoleUser: String?) throws {
        try ensureAndValidateStateDirectory(stateDirectory)
        let stateFD = try openValidatedDirectory(stateDirectory.path, owner: geteuid())
        defer { close(stateFD) }

        let sshFD = try openOrCreateDirectory(
            parentFD: stateFD,
            name: "ssh",
            mode: 0o700,
            owner: geteuid()
        )
        defer { close(sshFD) }

        try ensureHostKeyPair(sshFD: sshFD)
        guard let consoleUser, shouldInstallUserSSHFiles(consoleUser: consoleUser) else { return }

        guard let passwordEntry = getpwnam(consoleUser) else {
            throw SecureHostStateError.invalid("Console user does not exist: \(consoleUser)")
        }
        let userID = passwordEntry.pointee.pw_uid
        let groupID = passwordEntry.pointee.pw_gid
        let homePath = String(cString: passwordEntry.pointee.pw_dir)
        try installUserSSHFiles(
            sourceSSHFD: sshFD,
            homePath: homePath,
            userID: userID,
            groupID: groupID
        )
    }

    static func shouldInstallUserSSHFiles(consoleUser: String?) -> Bool {
        guard let consoleUser else { return false }
        return !consoleUser.isEmpty && consoleUser != "root" && consoleUser != "loginwindow"
    }

    static func installUserSSHFiles(
        sourceSSHFD: Int32,
        homePath: String,
        userID: uid_t,
        groupID: gid_t
    ) throws {
        let homeFD = try openValidatedDirectory(homePath, owner: userID)
        defer { close(homeFD) }

        let userSSHFD = try openOrCreateDirectory(
            parentFD: homeFD,
            name: ".ssh",
            mode: 0o700,
            owner: userID,
            group: groupID
        )
        defer { close(userSSHFD) }

        try atomicCopy(
            sourceParentFD: sourceSSHFD,
            sourceName: "id_ed25519",
            destinationParentFD: userSSHFD,
            destinationName: "darwin-vz-nix",
            mode: 0o600,
            owner: userID,
            group: groupID
        )
        try atomicCopy(
            sourceParentFD: sourceSSHFD,
            sourceName: "id_ed25519.pub",
            destinationParentFD: userSSHFD,
            destinationName: "darwin-vz-nix.pub",
            mode: 0o644,
            owner: userID,
            group: groupID
        )
        try ensureRegularFile(
            parentFD: userSSHFD,
            name: "darwin-vz-nix_known_hosts",
            mode: 0o600,
            owner: userID,
            group: groupID
        )
    }

    static func openAndLockStateDirectory(_ stateDirectory: URL) throws -> Int32 {
        try ensureAndValidateStateDirectory(stateDirectory, create: false)
        let stateFD = try openValidatedDirectory(stateDirectory.path, owner: geteuid())
        defer { close(stateFD) }

        return try openAndLockFile(in: stateFD)
    }

    private static func openAndLockFile(in stateFD: Int32) throws -> Int32 {
        var created = false
        var lockFD = openat(stateFD, "vm.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        if lockFD < 0, errno == ENOENT {
            lockFD = openat(
                stateFD,
                "vm.lock",
                O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
            if lockFD >= 0 {
                created = true
            } else if errno == EEXIST {
                lockFD = openat(stateFD, "vm.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            }
        }
        guard lockFD >= 0 else {
            throw SecureHostStateError.systemCall("openat vm.lock", errno)
        }
        do {
            if created { try clearExtendedACL(lockFD, path: "vm.lock") }
            guard fchmod(lockFD, 0o600) == 0 else {
                throw SecureHostStateError.systemCall("fchmod vm.lock", errno)
            }
            try validateDescriptor(lockFD, path: "vm.lock", kind: S_IFREG, owner: geteuid())
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                throw SecureHostStateError.systemCall("flock vm.lock", errno)
            }
            return lockFD
        } catch {
            close(lockFD)
            throw error
        }
    }

    static func openAndLockStateDirectoryForDestruction(
        _ stateDirectory: URL
    ) throws -> LockedStateDirectory {
        try ensureAndValidateStateDirectory(stateDirectory, create: false)
        let canonicalPath = canonicalSystemAliasPath(stateDirectory.path)
        let components = canonicalPath.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let name = components.last, components.count > 1 else {
            throw SecureHostStateError.invalid(
                "State directory must have a non-root parent: \(canonicalPath)"
            )
        }

        let stateFD = try openValidatedDirectory(canonicalPath, owner: geteuid())
        do {
            let parentPath = "/" + components.dropLast().joined(separator: "/")
            let parentFD = try openTrustedDirectory(parentPath, owner: geteuid())
            do {
                var stateInfo = stat()
                guard fstat(stateFD, &stateInfo) == 0 else {
                    throw SecureHostStateError.systemCall("fstat \(canonicalPath)", errno)
                }
                var namedInfo = stat()
                guard fstatat(parentFD, name, &namedInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw SecureHostStateError.systemCall("fstatat \(name)", errno)
                }
                guard namedInfo.st_mode & S_IFMT == S_IFDIR,
                      namedInfo.st_dev == stateInfo.st_dev,
                      namedInfo.st_ino == stateInfo.st_ino
                else {
                    throw SecureHostStateError.invalid(
                        "State directory changed while acquiring its lock: \(canonicalPath)"
                    )
                }

                let lockFD = try openAndLockFile(in: stateFD)
                return LockedStateDirectory(
                    stateFD: stateFD,
                    lockFD: lockFD,
                    parentFD: parentFD,
                    name: name,
                    device: stateInfo.st_dev,
                    inode: stateInfo.st_ino
                )
            } catch {
                close(parentFD)
                throw error
            }
        } catch {
            close(stateFD)
            throw error
        }
    }

    static func markIntentionalStop(
        stateDirectory: URL,
        pid: Int32,
        now: Date = Date(),
        nonce: String = UUID().uuidString,
        stageHook: ((DurableWriteStage) throws -> Void)? = nil
    ) throws -> IntentionalStopToken {
        let stateFD = try openValidatedDirectory(stateDirectory.path, owner: geteuid())
        defer { close(stateFD) }
        try unlinkValidatedRegularFileIfPresent(
            stateFD,
            name: intentionalStopAcknowledgementName
        )
        let token = IntentionalStopToken(
            pid: pid,
            createdAtSeconds: Int64(now.timeIntervalSince1970.rounded(.down)),
            nonce: nonce
        )
        let encoder = JSONEncoder()
        try atomicWrite(
            encoder.encode(token),
            parentFD: stateFD,
            name: intentionalStopMarkerName,
            mode: 0o600,
            owner: geteuid(),
            group: getegid(),
            syncParentDirectory: true,
            stageHook: stageHook
        )
        return token
    }

    static func validatedIntentionalStopToken(
        stateDirectory: URL,
        now: Date = Date()
    ) throws -> IntentionalStopToken? {
        let stateFD = try openValidatedDirectory(stateDirectory.path, owner: geteuid())
        defer { close(stateFD) }
        guard case let .live(token) = try inspectIntentionalStopMarker(stateFD, now: now).state else {
            return nil
        }
        return token
    }

    static func intentionalStopMarkerState(
        stateDirectory: URL,
        now: Date = Date()
    ) throws -> IntentionalStopMarkerState {
        let stateFD = try openValidatedDirectory(stateDirectory.path, owner: geteuid())
        defer { close(stateFD) }
        return try intentionalStopMarkerState(stateFD: stateFD, now: now)
    }

    static func intentionalStopMarkerState(
        stateFD: Int32,
        now: Date = Date()
    ) throws -> IntentionalStopMarkerState {
        try inspectIntentionalStopMarker(stateFD, now: now).state
    }

    private static func inspectIntentionalStopMarker(
        _ stateFD: Int32,
        now: Date
    ) throws -> IntentionalStopMarkerInspection {
        _ = now
        var metadata = stat()
        if fstatat(stateFD, intentionalStopMarkerName, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT {
                return IntentionalStopMarkerInspection(state: .absent, device: nil, inode: nil)
            }
            throw SecureHostStateError.systemCall("fstatat \(intentionalStopMarkerName)", errno)
        }
        try validate(metadata, path: intentionalStopMarkerName, kind: S_IFREG, owner: geteuid())
        let markerFD = openat(stateFD, intentionalStopMarkerName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard markerFD >= 0 else {
            throw SecureHostStateError.systemCall("openat \(intentionalStopMarkerName)", errno)
        }
        let markerData: Data
        var openedMetadata = stat()
        do {
            guard fstat(markerFD, &openedMetadata) == 0 else {
                throw SecureHostStateError.systemCall("fstat \(intentionalStopMarkerName)", errno)
            }
            try validateDescriptor(
                markerFD,
                path: intentionalStopMarkerName,
                kind: S_IFREG,
                owner: geteuid()
            )
            markerData = try readAll(
                markerFD,
                name: intentionalStopMarkerName,
                maximumBytes: intentionalStopTokenMaximumBytes
            )
            close(markerFD)
        } catch {
            close(markerFD)
            throw error
        }
        guard let token = try? JSONDecoder().decode(IntentionalStopToken.self, from: markerData) else {
            return IntentionalStopMarkerInspection(
                state: .invalid,
                device: openedMetadata.st_dev,
                inode: openedMetadata.st_ino
            )
        }
        guard token.pid > 0, !token.nonce.isEmpty else {
            return IntentionalStopMarkerInspection(
                state: .invalid,
                device: openedMetadata.st_dev,
                inode: openedMetadata.st_ino
            )
        }
        return IntentionalStopMarkerInspection(
            state: .live(token),
            device: openedMetadata.st_dev,
            inode: openedMetadata.st_ino
        )
    }

    static func clearIntentionalStop(stateDirectory: URL) throws {
        let stateFD = try openValidatedDirectory(stateDirectory.path, owner: geteuid())
        defer { close(stateFD) }
        try unlinkValidatedRegularFileIfPresent(stateFD, name: intentionalStopAcknowledgementName)
        try unlinkValidatedRegularFileIfPresent(stateFD, name: intentionalStopMarkerName)
    }

    static func clearInvalidIntentionalStop(stateDirectory: URL, now: Date = Date()) throws {
        let stateFD = try openValidatedDirectory(stateDirectory.path, owner: geteuid())
        defer { close(stateFD) }
        try clearInvalidIntentionalStop(stateFD: stateFD, now: now)
    }

    static func clearInvalidIntentionalStop(stateFD: Int32, now: Date = Date()) throws {
        let inspection = try inspectIntentionalStopMarker(stateFD, now: now)
        guard inspection.state == .invalid else { return }
        try unlinkValidatedRegularFileIfPresent(
            stateFD,
            name: intentionalStopAcknowledgementName
        )
        try unlinkValidatedRegularFileIfPresent(
            stateFD,
            name: intentionalStopMarkerName,
            expectedDevice: inspection.device,
            expectedInode: inspection.inode
        )
    }

    static func acknowledgeIntentionalStop(
        stateDirectory: URL,
        token: IntentionalStopToken,
        stageHook: ((DurableWriteStage) throws -> Void)? = nil
    ) throws {
        let stateFD = try openValidatedDirectory(stateDirectory.path, owner: geteuid())
        defer { close(stateFD) }
        try atomicWrite(
            JSONEncoder().encode(token),
            parentFD: stateFD,
            name: intentionalStopAcknowledgementName,
            mode: 0o600,
            owner: geteuid(),
            group: getegid(),
            syncParentDirectory: true,
            stageHook: stageHook
        )
    }

    static func hasIntentionalStopAcknowledgement(
        stateDirectory: URL,
        expectedToken: IntentionalStopToken
    ) throws -> Bool {
        let stateFD = try openValidatedDirectory(stateDirectory.path, owner: geteuid())
        defer { close(stateFD) }
        return try hasIntentionalStopAcknowledgement(
            stateFD: stateFD,
            expectedToken: expectedToken
        )
    }

    static func hasIntentionalStopAcknowledgement(
        stateFD: Int32,
        expectedToken: IntentionalStopToken
    ) throws -> Bool {
        var metadata = stat()
        if fstatat(stateFD, intentionalStopAcknowledgementName, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return false }
            throw SecureHostStateError.systemCall(
                "fstatat \(intentionalStopAcknowledgementName)",
                errno
            )
        }
        try validate(
            metadata,
            path: intentionalStopAcknowledgementName,
            kind: S_IFREG,
            owner: geteuid()
        )
        let acknowledgementFD = openat(
            stateFD,
            intentionalStopAcknowledgementName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard acknowledgementFD >= 0 else {
            throw SecureHostStateError.systemCall(
                "openat \(intentionalStopAcknowledgementName)",
                errno
            )
        }
        defer { close(acknowledgementFD) }
        try validateDescriptor(
            acknowledgementFD,
            path: intentionalStopAcknowledgementName,
            kind: S_IFREG,
            owner: geteuid()
        )
        let data = try readAll(
            acknowledgementFD,
            name: intentionalStopAcknowledgementName,
            maximumBytes: intentionalStopTokenMaximumBytes
        )
        guard let token = try? JSONDecoder().decode(IntentionalStopToken.self, from: data) else {
            return false
        }
        return token == expectedToken
    }

    static func hasIntentionalStopMarker(stateDirectory: URL) throws -> Bool {
        try hasValidatedArtifact(
            stateDirectory: stateDirectory,
            name: intentionalStopMarkerName
        )
    }

    private static func hasValidatedArtifact(stateDirectory: URL, name: String) throws -> Bool {
        let stateFD = try openValidatedDirectory(stateDirectory.path, owner: geteuid())
        defer { close(stateFD) }
        return try childExistsAndIsValid(
            stateFD,
            name: name,
            kind: S_IFREG,
            owner: geteuid()
        )
    }

    static func waitForIntentionalStopAcknowledgement(
        stateDirectory: URL,
        expectedToken: IntentionalStopToken,
        timeout: TimeInterval = 5,
        pollIntervalMicroseconds: UInt32 = 20000
    ) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try hasIntentionalStopAcknowledgement(
                stateDirectory: stateDirectory,
                expectedToken: expectedToken
            ) {
                return true
            }
            if Date() >= deadline { return false }
            usleep(pollIntervalMicroseconds)
        } while true
    }

    static func waitForIntentionalStopAcknowledgement(
        stateFD: Int32,
        expectedToken: IntentionalStopToken,
        timeout: TimeInterval = 5,
        pollIntervalMicroseconds: UInt32 = 20000
    ) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try hasIntentionalStopAcknowledgement(
                stateFD: stateFD,
                expectedToken: expectedToken
            ) {
                return true
            }
            if Date() >= deadline { return false }
            usleep(pollIntervalMicroseconds)
        } while true
    }

    private static func unlinkValidatedRegularFileIfPresent(
        _ parentFD: Int32,
        name: String,
        expectedDevice: dev_t? = nil,
        expectedInode: ino_t? = nil
    ) throws {
        let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return }
            throw SecureHostStateError.systemCall("openat \(name)", errno)
        }
        defer { close(fd) }

        var openedMetadata = stat()
        guard fstat(fd, &openedMetadata) == 0 else {
            throw SecureHostStateError.systemCall("fstat \(name)", errno)
        }
        try validate(openedMetadata, path: name, kind: S_IFREG, owner: geteuid())
        if let expectedDevice, openedMetadata.st_dev != expectedDevice {
            throw SecureHostStateError.invalid("Artifact changed before cleanup: \(name)")
        }
        if let expectedInode, openedMetadata.st_ino != expectedInode {
            throw SecureHostStateError.invalid("Artifact changed before cleanup: \(name)")
        }

        var linkedMetadata = stat()
        guard fstatat(parentFD, name, &linkedMetadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw SecureHostStateError.systemCall("fstatat \(name)", errno)
        }
        guard linkedMetadata.st_dev == openedMetadata.st_dev,
              linkedMetadata.st_ino == openedMetadata.st_ino
        else {
            throw SecureHostStateError.invalid("Artifact changed before unlink: \(name)")
        }
        if unlinkat(parentFD, name, 0) != 0, errno != ENOENT {
            throw SecureHostStateError.systemCall("unlinkat \(name)", errno)
        }
    }

    static func ensureHostKeyPair(
        sshFD: Int32,
        keyGenerationRootPath: String = "/private/var/root",
        keyGenerationOwner: uid_t = 0
    ) throws {
        let privateExists = try childExistsAndIsValid(sshFD, name: "id_ed25519", kind: S_IFREG, owner: geteuid())
        _ = try childExistsAndIsValid(sshFD, name: "id_ed25519.pub", kind: S_IFREG, owner: geteuid())

        guard geteuid() == keyGenerationOwner else {
            throw SecureHostStateError.invalid("Host key generation root has an unexpected owner")
        }
        let temporaryRootFD = try openDirectoryPath(
            keyGenerationRootPath,
            owner: keyGenerationOwner,
            createMissingComponents: false
        )
        defer { close(temporaryRootFD) }
        let temporaryName = ".darwin-vz-nix-keygen.\(UUID().uuidString)"
        let temporaryFD = try openOrCreateDirectory(
            parentFD: temporaryRootFD,
            name: temporaryName,
            mode: 0o700,
            owner: keyGenerationOwner
        )
        defer {
            _ = unlinkat(temporaryFD, "id_ed25519", 0)
            _ = unlinkat(temporaryFD, "id_ed25519.pub", 0)
            close(temporaryFD)
            _ = unlinkat(temporaryRootFD, temporaryName, AT_REMOVEDIR)
        }

        let temporaryKeyPath = "\(keyGenerationRootPath)/\(temporaryName)/id_ed25519"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        if privateExists {
            try atomicCopy(
                sourceParentFD: sshFD,
                sourceName: "id_ed25519",
                destinationParentFD: temporaryFD,
                destinationName: "id_ed25519",
                mode: 0o600,
                owner: keyGenerationOwner,
                group: getegid()
            )
            let output = Pipe()
            process.standardOutput = output
            process.arguments = ["-y", "-f", temporaryKeyPath]
            try process.run()
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw SecureHostStateError.invalid("ssh-keygen failed with status \(process.terminationStatus)")
            }
            let derivedKeyData = output.fileHandleForReading.readDataToEndOfFile()
            guard let derivedKey = String(data: derivedKeyData, encoding: .utf8) else {
                throw SecureHostStateError.invalid("ssh-keygen returned a non-UTF-8 public key")
            }
            let publicKey = Data(
                "\(derivedKey.trimmingCharacters(in: .whitespacesAndNewlines)) builder@darwin-vz-nix\n".utf8
            )
            try atomicWrite(
                publicKey,
                parentFD: sshFD,
                name: "id_ed25519.pub",
                mode: 0o644,
                owner: geteuid(),
                group: getegid()
            )
            return
        }

        process.arguments = [
            "-q", "-f", temporaryKeyPath,
            "-t", "ed25519", "-N", "", "-C", "builder@darwin-vz-nix",
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw SecureHostStateError.invalid("ssh-keygen failed with status \(process.terminationStatus)")
        }
        try validateChildIfPresent(
            temporaryFD,
            name: "id_ed25519",
            kind: S_IFREG,
            owner: keyGenerationOwner,
            required: true
        )
        try validateChildIfPresent(
            temporaryFD,
            name: "id_ed25519.pub",
            kind: S_IFREG,
            owner: keyGenerationOwner,
            required: true
        )
        try atomicCopy(
            sourceParentFD: temporaryFD,
            sourceName: "id_ed25519",
            destinationParentFD: sshFD,
            destinationName: "id_ed25519",
            mode: 0o600,
            owner: geteuid(),
            group: getegid()
        )
        try atomicCopy(
            sourceParentFD: temporaryFD,
            sourceName: "id_ed25519.pub",
            destinationParentFD: sshFD,
            destinationName: "id_ed25519.pub",
            mode: 0o644,
            owner: geteuid(),
            group: getegid()
        )
    }

    private static func openValidatedDirectory(_ path: String, owner: uid_t) throws -> Int32 {
        try openDirectoryPath(path, owner: owner, createMissingComponents: false)
    }

    private static func openTrustedDirectory(_ path: String, owner: uid_t) throws -> Int32 {
        let path = canonicalSystemAliasPath(path)
        guard path.hasPrefix("/") else {
            throw SecureHostStateError.invalid("Directory must be absolute: \(path)")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw SecureHostStateError.invalid("Directory path contains an unsafe component: \(path)")
        }

        var currentFD = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard currentFD >= 0 else {
            throw SecureHostStateError.systemCall("open root directory", errno)
        }
        do {
            for component in components {
                let nextFD = openat(
                    currentFD,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard nextFD >= 0 else {
                    throw SecureHostStateError.systemCall("openat directory component \(component)", errno)
                }
                try validateTrustedAncestor(nextFD, path: component, owner: owner)
                close(currentFD)
                currentFD = nextFD
            }
            return currentFD
        } catch {
            close(currentFD)
            throw error
        }
    }

    private static func openDirectoryPath(
        _ path: String,
        owner: uid_t,
        createMissingComponents: Bool
    ) throws -> Int32 {
        let path = canonicalSystemAliasPath(path)
        guard path.hasPrefix("/"), path != "/" else {
            throw SecureHostStateError.invalid("Directory must be an absolute non-root path: \(path)")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw SecureHostStateError.invalid("Directory path contains an unsafe component: \(path)")
        }

        var currentFD = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard currentFD >= 0 else {
            throw SecureHostStateError.systemCall("open root directory", errno)
        }
        do {
            for component in components {
                var created = false
                var nextFD = openat(
                    currentFD,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                if nextFD < 0, errno == ENOENT, createMissingComponents {
                    guard mkdirat(currentFD, component, 0o755) == 0 else {
                        throw SecureHostStateError.systemCall("mkdirat \(component)", errno)
                    }
                    created = true
                    nextFD = openat(
                        currentFD,
                        component,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard nextFD >= 0 else {
                    throw SecureHostStateError.systemCall("openat directory component \(component)", errno)
                }
                if created { try clearExtendedACL(nextFD, path: component) }
                try validateTrustedAncestor(nextFD, path: component, owner: owner)
                close(currentFD)
                currentFD = nextFD
            }
            try validateDescriptor(currentFD, path: path, kind: S_IFDIR, owner: owner)
            return currentFD
        } catch {
            close(currentFD)
            throw error
        }
    }

    static func canonicalSystemAliasPath(_ path: String) -> String {
        for (alias, target) in [("/var", "/private/var"), ("/tmp", "/private/tmp"), ("/etc", "/private/etc")] {
            if path == alias { return target }
            if path.hasPrefix(alias + "/") { return target + path.dropFirst(alias.count) }
        }
        return path
    }

    private static func openOrCreateDirectory(
        parentFD: Int32,
        name: String,
        mode: mode_t,
        owner: uid_t,
        group: gid_t? = nil
    ) throws -> Int32 {
        var fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT {
            guard mkdirat(parentFD, name, mode) == 0 else {
                throw SecureHostStateError.systemCall("mkdirat \(name)", errno)
            }
            fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                throw SecureHostStateError.systemCall("openat directory \(name)", errno)
            }
            try clearExtendedACL(fd, path: name)
            guard fchmod(fd, mode) == 0 else {
                close(fd)
                throw SecureHostStateError.systemCall("fchmod \(name)", errno)
            }
            if let group, fchown(fd, owner, group) != 0 {
                close(fd)
                throw SecureHostStateError.systemCall("fchown \(name)", errno)
            }
        } else if fd < 0 {
            throw SecureHostStateError.systemCall("openat directory \(name)", errno)
        }
        do {
            guard fchmod(fd, mode) == 0 else {
                throw SecureHostStateError.systemCall("fchmod \(name)", errno)
            }
            if let group, fchown(fd, owner, group) != 0 {
                throw SecureHostStateError.systemCall("fchown \(name)", errno)
            }
            try validateDescriptor(fd, path: name, kind: S_IFDIR, owner: owner)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func atomicCopy(
        sourceParentFD: Int32,
        sourceName: String,
        destinationParentFD: Int32,
        destinationName: String,
        mode: mode_t,
        owner: uid_t,
        group: gid_t
    ) throws {
        let sourceFD = openat(sourceParentFD, sourceName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else {
            throw SecureHostStateError.systemCall("openat \(sourceName)", errno)
        }
        defer { close(sourceFD) }
        let containsPrivateKey = !sourceName.hasSuffix(".pub")
        try validateDescriptor(
            sourceFD,
            path: sourceName,
            kind: S_IFREG,
            owner: geteuid(),
            rejectNonOwnerReadAccess: containsPrivateKey
        )

        let maximumBytes = sourceName.hasSuffix(".pub")
            ? publicKeyMaximumBytes
            : privateKeyMaximumBytes
        let data = try readAll(sourceFD, name: sourceName, maximumBytes: maximumBytes)
        try atomicWrite(
            data,
            parentFD: destinationParentFD,
            name: destinationName,
            mode: mode,
            owner: owner,
            group: group
        )
    }

    private static func readAll(_ fd: Int32, name: String, maximumBytes: Int) throws -> Data {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else {
            throw SecureHostStateError.systemCall("fstat \(name)", errno)
        }
        guard metadata.st_size >= 0, metadata.st_size <= off_t(maximumBytes) else {
            throw SecureHostStateError.invalid("File exceeds the size limit: \(name)")
        }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: min(16384, maximumBytes + 1))
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw SecureHostStateError.systemCall("read \(name)", errno)
            }
            guard count <= maximumBytes - data.count else {
                throw SecureHostStateError.invalid("File exceeds the size limit: \(name)")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static func atomicWrite(
        _ data: Data,
        parentFD: Int32,
        name: String,
        mode: mode_t,
        owner: uid_t,
        group: gid_t,
        syncParentDirectory: Bool = false,
        stageHook: ((DurableWriteStage) throws -> Void)? = nil
    ) throws {
        try validateChildIfPresent(parentFD, name: name, kind: S_IFREG, owner: owner)
        let temporaryName = ".\(name).tmp.\(UUID().uuidString)"
        let fd = openat(parentFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else {
            throw SecureHostStateError.systemCall("openat temporary \(temporaryName)", errno)
        }
        var shouldUnlink = true
        defer {
            close(fd)
            if shouldUnlink { _ = unlinkat(parentFD, temporaryName, 0) }
        }
        try clearExtendedACL(fd, path: temporaryName)
        try stageHook?(.write)
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let written = write(fd, rawBuffer.baseAddress!.advanced(by: offset), rawBuffer.count - offset)
                guard written >= 0 else {
                    if errno == EINTR { continue }
                    throw SecureHostStateError.systemCall("write temporary \(temporaryName)", errno)
                }
                offset += written
            }
        }
        guard fchmod(fd, mode) == 0 else {
            throw SecureHostStateError.systemCall("fchmod temporary \(temporaryName)", errno)
        }
        guard fchown(fd, owner, group) == 0 else {
            throw SecureHostStateError.systemCall("fchown temporary \(temporaryName)", errno)
        }
        try validateDescriptor(fd, path: temporaryName, kind: S_IFREG, owner: owner)
        guard fsync(fd) == 0 else {
            throw SecureHostStateError.systemCall("fsync temporary \(temporaryName)", errno)
        }
        try stageHook?(.rename)
        guard renameat(parentFD, temporaryName, parentFD, name) == 0 else {
            throw SecureHostStateError.systemCall("renameat \(name)", errno)
        }
        shouldUnlink = false
        if syncParentDirectory {
            do {
                try stageHook?(.directorySync)
                guard fsync(parentFD) == 0 else {
                    throw SecureHostStateError.systemCall("fsync parent directory for \(name)", errno)
                }
            } catch {
                var renamedMetadata = stat()
                if fstat(fd, &renamedMetadata) == 0 {
                    try? unlinkValidatedRegularFileIfPresent(
                        parentFD,
                        name: name,
                        expectedDevice: renamedMetadata.st_dev,
                        expectedInode: renamedMetadata.st_ino
                    )
                }
                _ = fsync(parentFD)
                throw error
            }
        }
    }

    private static func ensureRegularFile(
        parentFD: Int32,
        name: String,
        mode: mode_t,
        owner: uid_t,
        group: gid_t
    ) throws {
        if try childExistsAndIsValid(parentFD, name: name, kind: S_IFREG, owner: owner) {
            let fd = openat(parentFD, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw SecureHostStateError.systemCall("openat \(name)", errno) }
            defer { close(fd) }
            try validateDescriptor(fd, path: name, kind: S_IFREG, owner: owner)
            guard fchmod(fd, mode) == 0, fchown(fd, owner, group) == 0 else {
                throw SecureHostStateError.systemCall("secure \(name)", errno)
            }
            return
        }
        try atomicWrite(Data(), parentFD: parentFD, name: name, mode: mode, owner: owner, group: group)
    }

    private static func childExistsAndIsValid(
        _ parentFD: Int32,
        name: String,
        kind: mode_t,
        owner: uid_t
    ) throws -> Bool {
        var metadata = stat()
        if fstatat(parentFD, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return false }
            throw SecureHostStateError.systemCall("fstatat \(name)", errno)
        }
        try validate(metadata, path: name, kind: kind, owner: owner)
        var flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        if kind == S_IFDIR { flags |= O_DIRECTORY }
        let fd = openat(parentFD, name, flags)
        guard fd >= 0 else {
            throw SecureHostStateError.systemCall("openat \(name)", errno)
        }
        defer { close(fd) }
        try validateDescriptor(fd, path: name, kind: kind, owner: owner)
        return true
    }

    private static func validateChildIfPresent(
        _ parentFD: Int32,
        name: String,
        kind: mode_t,
        owner: uid_t,
        required: Bool = false
    ) throws {
        let exists = try childExistsAndIsValid(parentFD, name: name, kind: kind, owner: owner)
        if required, !exists {
            throw SecureHostStateError.invalid("Required artifact is missing: \(name)")
        }
    }

    private static func validateDescriptor(
        _ fd: Int32,
        path: String,
        kind: mode_t,
        owner: uid_t,
        rejectNonOwnerReadAccess: Bool = false
    ) throws {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else {
            throw SecureHostStateError.systemCall("fstat \(path)", errno)
        }
        try validate(metadata, path: path, kind: kind, owner: owner)
        try validateExtendedACL(
            fd,
            path: path,
            owner: metadata.st_uid,
            rejectNonOwnerReadAccess: rejectNonOwnerReadAccess
        )
    }

    private static func validateTrustedAncestor(_ fd: Int32, path: String, owner: uid_t) throws {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else {
            throw SecureHostStateError.systemCall("fstat ancestor \(path)", errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw SecureHostStateError.invalid("Unsafe ancestor type at \(path)")
        }
        guard metadata.st_uid == 0 || metadata.st_uid == owner else {
            throw SecureHostStateError.invalid("Untrusted ancestor owner at \(path): uid \(metadata.st_uid)")
        }
        guard metadata.st_mode & 0o022 == 0 else {
            throw SecureHostStateError.invalid("Group/world-writable ancestor rejected: \(path)")
        }
        try validateExtendedACL(fd, path: path, owner: metadata.st_uid)
    }

    private static func clearExtendedACL(_ fd: Int32, path: String) throws {
        guard let acl = acl_init(0) else {
            throw SecureHostStateError.systemCall("acl_init \(path)", errno)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 else {
            throw SecureHostStateError.systemCall("acl_set_fd_np \(path)", errno)
        }
    }

    private static func validateExtendedACL(
        _ fd: Int32,
        path: String,
        owner: uid_t,
        rejectNonOwnerReadAccess: Bool = false
    ) throws {
        let descriptorACL = acl_get_fd_np(fd, ACL_TYPE_EXTENDED)
        if descriptorACL == nil, errno == ENOENT { return }
        guard let acl = descriptorACL else {
            throw SecureHostStateError.systemCall("acl_get_fd_np \(path)", errno)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }

        var ownerUUID: DarwinUUID = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
        guard membershipUIDToUUID(owner, &ownerUUID) == 0 else {
            throw SecureHostStateError.systemCall("mbr_uid_to_uuid \(path)", errno)
        }

        var entry: acl_entry_t?
        var result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        while result == 0 {
            guard let currentEntry = entry else {
                throw SecureHostStateError.invalid("Malformed extended ACL at \(path)")
            }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(currentEntry, &tag) == 0 else {
                throw SecureHostStateError.systemCall("acl_get_tag_type \(path)", errno)
            }
            if tag == ACL_EXTENDED_ALLOW {
                var permissions: acl_permset_t?
                guard acl_get_permset(currentEntry, &permissions) == 0, let permissions else {
                    throw SecureHostStateError.systemCall("acl_get_permset \(path)", errno)
                }
                let mutatesPathOrContent = [
                    ACL_WRITE_DATA,
                    ACL_APPEND_DATA,
                    ACL_DELETE,
                    ACL_DELETE_CHILD,
                    ACL_WRITE_ATTRIBUTES,
                    ACL_WRITE_EXTATTRIBUTES,
                    ACL_WRITE_SECURITY,
                    ACL_CHANGE_OWNER,
                ].contains { acl_get_perm_np(permissions, $0) == 1 }
                if mutatesPathOrContent, !aclEntry(currentEntry, belongsTo: ownerUUID) {
                    throw SecureHostStateError.invalid(
                        "Non-owner mutating allow ACL rejected: \(path)"
                    )
                }
                let readsContent = acl_get_perm_np(permissions, ACL_READ_DATA) == 1
                if rejectNonOwnerReadAccess,
                   readsContent,
                   !aclEntry(currentEntry, belongsTo: ownerUUID)
                {
                    throw SecureHostStateError.invalid(
                        "Non-owner read allow ACL rejected for private content: \(path)"
                    )
                }
            }
            result = acl_get_entry(acl, ACL_NEXT_ENTRY.rawValue, &entry)
        }
        guard result == -1, errno == EINVAL else {
            throw SecureHostStateError.systemCall("acl_get_entry \(path)", errno)
        }
    }

    private static func aclEntry(_ entry: acl_entry_t, belongsTo ownerUUID: DarwinUUID) -> Bool {
        guard let qualifier = acl_get_qualifier(entry) else { return false }
        defer { acl_free(qualifier) }
        return withUnsafeBytes(of: ownerUUID) { ownerBytes in
            memcmp(qualifier, ownerBytes.baseAddress!, ownerBytes.count) == 0
        }
    }

    private static func validate(_ metadata: stat, path: String, kind: mode_t, owner: uid_t) throws {
        guard metadata.st_mode & S_IFMT == kind else {
            throw SecureHostStateError.invalid("Unsafe file type at \(path)")
        }
        guard metadata.st_uid == owner else {
            throw SecureHostStateError.invalid("Unexpected owner at \(path): uid \(metadata.st_uid), expected \(owner)")
        }
        guard metadata.st_mode & 0o022 == 0 else {
            throw SecureHostStateError.invalid("Group/world-writable path rejected: \(path)")
        }
    }
}
