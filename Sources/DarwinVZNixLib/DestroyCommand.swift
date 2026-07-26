import ArgumentParser
import Foundation

public struct Destroy: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Destroy all VM state (stop VM if running and delete all state files)"
    )

    @Flag(name: .long, help: "Skip confirmation prompt")
    var yes: Bool = false

    @Option(name: .long, help: "State directory for VM data (default: ~/.local/share/darwin-vz-nix)")
    var stateDir: String?

    public init() {}

    public mutating func run() async throws {
        let stateDirectory = stateDir.map { URL(fileURLWithPath: $0) } ?? VMConfig.defaultStateDirectory
        let pidFileURL = stateDirectory.appendingPathComponent("vm.pid")

        // Confirm BEFORE any side effect. Stopping the VM is part of destroy,
        // so it must be gated by the same confirmation: a cancelled destroy
        // must leave a running VM running.
        if !yes {
            guard isatty(STDIN_FILENO) != 0 else {
                throw ValidationError(
                    "stdin is not a terminal. Use --yes to skip confirmation."
                )
            }
            print("This will permanently delete all VM state in \(stateDirectory.path).")
            print("Continue? [y/N]: ", terminator: "")
            fflush(stdout)
            let input = (readLine(strippingNewline: true) ?? "").lowercased().trimmingCharacters(
                in: .whitespaces
            )
            guard input == "y" else {
                throw CleanExit.message("Destroy cancelled.")
            }
        }

        var stateMetadata = stat()
        if lstat(stateDirectory.path, &stateMetadata) == 0 {
            try SecureHostState.ensureAndValidateStateDirectory(stateDirectory, create: false)
        } else if errno != ENOENT {
            throw SecureHostStateError.systemCall("lstat \(stateDirectory.path)", errno)
        }

        var expectedStopAcknowledgement: SecureHostState.IntentionalStopToken?

        // Auto-stop VM if running. Treat reused/dead PID files as stale, but never signal an
        // unrelated process before deleting state.
        if let record = VMManager.readPIDRecord(from: pidFileURL) {
            if VMManager.isProcessRunning(pid: record.pid) {
                if VMManager.processMatchesRecord(record, pidFileURL: pidFileURL) {
                    print("VM is running. Stopping before destroying state...")
                    if record.launchdManaged {
                        expectedStopAcknowledgement = try SecureHostState.markIntentionalStop(
                            stateDirectory: stateDirectory,
                            pid: record.pid
                        )
                    }
                    let termination = try VMManager.terminateProcess(
                        pid: record.pid,
                        pidFileURL: pidFileURL
                    )
                    if !termination.stopped {
                        if record.launchdManaged {
                            try? SecureHostState.clearIntentionalStop(stateDirectory: stateDirectory)
                        }
                        throw VMManagerError.stopFailed(
                            "VM process \(record.pid) could not be stopped. Aborting destroy."
                        )
                    }
                    if record.launchdManaged, !termination.usedSIGKILL {
                        try SecureHostState.clearIntentionalStop(stateDirectory: stateDirectory)
                        expectedStopAcknowledgement = nil
                    }
                } else {
                    print("Stale PID file detected.")
                }
            }
        }

        // Nothing to delete if the state directory does not exist.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: stateDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            print("VM state destroyed.")
            return
        }

        // Hold the exclusive state-directory flock while deleting. The PID file
        // alone is not enough: a `start` that is still booting has not written
        // vm.pid yet (and a corrupted/hand-deleted PID file also reads as "not
        // running"), but it already holds this flock and has disk.img open
        // read-write — deleting the image under it would corrupt the guest.
        // The held lock also excludes a concurrent `start` for the duration of
        // the deletion.
        guard let lockedState = try? SecureHostState.openAndLockStateDirectoryForDestruction(
            stateDirectory
        ) else {
            try exitOperational(
                "Could not acquire the VM state lock for \(stateDirectory.path). "
                    + "A VM is still starting or running for this state directory. Aborting destroy."
            )
        }

        if expectedStopAcknowledgement == nil {
            switch try SecureHostState.intentionalStopMarkerState(
                stateFD: lockedState.stateFD
            ) {
            case .absent:
                break
            case .live:
                try exitOperational(
                    "An unresolved intentional-stop marker is still present. "
                        + "State was preserved to prevent an unintended launchd restart during destroy."
                )
            case .invalid:
                try SecureHostState.clearInvalidIntentionalStop(stateFD: lockedState.stateFD)
            }
        }

        if let expectedStopAcknowledgement,
           try !(SecureHostState.waitForIntentionalStopAcknowledgement(
               stateFD: lockedState.stateFD,
               expectedToken: expectedStopAcknowledgement
           ))
        {
            try exitOperational(
                "launchd did not acknowledge the intentional VM stop. "
                    + "State was preserved to prevent an unintended restart during destroy."
            )
        }

        // Host-key pins represent this VM identity. Preserve them across normal
        // restarts, but remove them once the identity is explicitly destroyed.
        let networkManager = NetworkManager(stateDirectory: stateDirectory)
        networkManager.scrubStateKnownHosts()
        NetworkManager.scrubUserKnownHosts()

        try lockedState.validateOriginalName()
        try Self.deleteKnownArtifacts(in: lockedState)

        // The docs promise `destroy` removes the entire state directory. Remove
        // it too — via rmdir(2), which only removes an EMPTY directory: a
        // `--state-dir` that (mis)points at a shared directory can never take
        // unrelated files down with it, and unlike a check-then-removeItem
        // sequence this cannot race a concurrent file creation into a recursive
        // delete. A leftover non-darwin-vz-nix file leaves the directory in
        // place, by design.
        let removalResult = try Self.finalizeStateDirectory(lockedState)
        print(Self.completionMessage(for: removalResult, stateDirectory: stateDirectory))
    }

    enum StateDirectoryRemovalResult: Equatable {
        case removed
        case preservedUnknownContents
    }

    static func removeStateDirectory(_ stateDirectory: URL) throws -> StateDirectoryRemovalResult {
        if rmdir(stateDirectory.path) == 0 {
            return .removed
        }
        switch errno {
        case ENOENT:
            return .removed
        case ENOTEMPTY:
            return .preservedUnknownContents
        default:
            throw SecureHostStateError.systemCall("rmdir \(stateDirectory.path)", errno)
        }
    }

    static func completionMessage(
        for result: StateDirectoryRemovalResult,
        stateDirectory: URL
    ) -> String {
        switch result {
        case .removed:
            "VM state destroyed."
        case .preservedUnknownContents:
            "Known VM state was destroyed, but \(stateDirectory.path) was preserved because it contains unrelated files."
        }
    }

    private enum ArtifactKind {
        case regularFile
        case nixStoreSymlink
    }

    private static let topLevelArtifacts: [(String, ArtifactKind)] = [
        ("disk.img", .regularFile),
        ("vm.pid", .regularFile),
        ("console.log", .regularFile),
        ("daemon.log", .regularFile),
        ("guest-ip", .regularFile),
        (SecureHostState.intentionalStopMarkerName, .regularFile),
        (SecureHostState.intentionalStopAcknowledgementName, .regularFile),
    ]

    private static let directoryArtifacts: [(String, [(String, ArtifactKind)])] = [
        ("ssh", [
            ("id_ed25519", .regularFile),
            ("id_ed25519.pub", .regularFile),
            ("known_hosts", .regularFile),
        ]),
        ("ssh-pub", [("id_ed25519.pub", .regularFile)]),
        ("gcroots", [
            ("kernel", .nixStoreSymlink),
            ("initrd", .nixStoreSymlink),
            ("system", .nixStoreSymlink),
        ]),
    ]

    /// Deletes only VM artifacts whose type, owner, and inode still match the
    /// descriptor-relative object inspected by this process. The hook exists so
    /// tests can deterministically replace a leaf between inspection and unlink.
    static func deleteKnownArtifacts(
        in stateDirectory: URL,
        afterOpeningArtifact: ((String) throws -> Void)? = nil
    ) throws {
        let stateFD = open(
            stateDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard stateFD >= 0 else {
            throw SecureHostStateError.systemCall("open \(stateDirectory.path)", errno)
        }
        defer { close(stateFD) }

        var stateInfo = stat()
        guard fstat(stateFD, &stateInfo) == 0 else {
            throw SecureHostStateError.systemCall("fstat \(stateDirectory.path)", errno)
        }
        guard stateInfo.st_mode & S_IFMT == S_IFDIR, stateInfo.st_uid == geteuid() else {
            return
        }

        for (name, kind) in topLevelArtifacts {
            try deleteKnownLeaf(
                parentFD: stateFD,
                name: name,
                kind: kind,
                logicalPath: name,
                afterOpeningArtifact: afterOpeningArtifact
            )
        }

        for (directoryName, leaves) in directoryArtifacts {
            try deleteKnownDirectory(
                parentFD: stateFD,
                name: directoryName,
                leaves: leaves,
                afterOpeningArtifact: afterOpeningArtifact
            )
        }

        // Keep the lock name linked until every other known artifact is gone.
        // Otherwise a concurrent start could create and lock a new inode while
        // destroy still holds the now-unlinked old lock inode.
        try deleteKnownLeaf(
            parentFD: stateFD,
            name: "vm.lock",
            kind: .regularFile,
            logicalPath: "vm.lock",
            afterOpeningArtifact: afterOpeningArtifact
        )
    }

    static func deleteKnownArtifacts(
        in lockedState: SecureHostState.LockedStateDirectory,
        afterOpeningArtifact: ((String) throws -> Void)? = nil
    ) throws {
        try lockedState.validateOriginalName()
        try deleteKnownArtifacts(
            stateFD: lockedState.stateFD,
            deleteLock: false,
            afterOpeningArtifact: afterOpeningArtifact
        )
        try lockedState.validateOriginalName()
    }

    private static func deleteKnownArtifacts(
        stateFD: Int32,
        deleteLock: Bool,
        afterOpeningArtifact: ((String) throws -> Void)?
    ) throws {
        for (name, kind) in topLevelArtifacts {
            try deleteKnownLeaf(
                parentFD: stateFD,
                name: name,
                kind: kind,
                logicalPath: name,
                afterOpeningArtifact: afterOpeningArtifact
            )
        }

        for (directoryName, leaves) in directoryArtifacts {
            try deleteKnownDirectory(
                parentFD: stateFD,
                name: directoryName,
                leaves: leaves,
                afterOpeningArtifact: afterOpeningArtifact
            )
        }

        if deleteLock {
            try deleteKnownLeaf(
                parentFD: stateFD,
                name: "vm.lock",
                kind: .regularFile,
                logicalPath: "vm.lock",
                afterOpeningArtifact: afterOpeningArtifact
            )
        }
    }

    static func finalizeStateDirectory(
        _ lockedState: SecureHostState.LockedStateDirectory,
        afterRenaming: (() throws -> Void)? = nil
    ) throws -> StateDirectoryRemovalResult {
        try lockedState.validateOriginalName()
        guard try !containsEntryOtherThanLock(lockedState.stateFD) else {
            try deleteKnownLeaf(
                parentFD: lockedState.stateFD,
                name: "vm.lock",
                kind: .regularFile,
                logicalPath: "vm.lock",
                afterOpeningArtifact: nil
            )
            return .preservedUnknownContents
        }

        let tombstoneName = ".darwin-vz-nix-destroy-\(UUID().uuidString)"
        guard renameatx_np(
            lockedState.parentFD,
            lockedState.name,
            lockedState.parentFD,
            tombstoneName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw SecureHostStateError.systemCall("renameatx_np \(lockedState.name)", errno)
        }

        var tombstoneInfo = stat()
        guard fstatat(
            lockedState.parentFD,
            tombstoneName,
            &tombstoneInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
            tombstoneInfo.st_dev == lockedState.device,
            tombstoneInfo.st_ino == lockedState.inode
        else {
            throw SecureHostStateError.invalid("Destroy tombstone does not reference the locked state directory")
        }

        try afterRenaming?()
        try deleteKnownLeaf(
            parentFD: lockedState.stateFD,
            name: "vm.lock",
            kind: .regularFile,
            logicalPath: "vm.lock",
            afterOpeningArtifact: nil
        )
        guard unlinkat(lockedState.parentFD, tombstoneName, AT_REMOVEDIR) == 0 else {
            throw SecureHostStateError.systemCall("unlinkat \(tombstoneName)", errno)
        }
        return .removed
    }

    private static func containsEntryOtherThanLock(_ stateFD: Int32) throws -> Bool {
        let duplicateFD = fcntl(stateFD, F_DUPFD_CLOEXEC, 0)
        guard duplicateFD >= 0 else {
            throw SecureHostStateError.systemCall("fcntl state directory", errno)
        }
        guard let directory = fdopendir(duplicateFD) else {
            let code = errno
            close(duplicateFD)
            throw SecureHostStateError.systemCall("fdopendir state directory", code)
        }
        defer { closedir(directory) }

        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != "..", name != "vm.lock" {
                return true
            }
        }
        return false
    }

    private static func deleteKnownDirectory(
        parentFD: Int32,
        name: String,
        leaves: [(String, ArtifactKind)],
        afterOpeningArtifact: ((String) throws -> Void)?
    ) throws {
        let directoryFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directoryFD < 0 {
            if errno == ENOENT || errno == ELOOP || errno == ENOTDIR { return }
            throw SecureHostStateError.systemCall("openat \(name)", errno)
        }
        defer { close(directoryFD) }

        var openedInfo = stat()
        guard fstat(directoryFD, &openedInfo) == 0 else {
            throw SecureHostStateError.systemCall("fstat \(name)", errno)
        }
        guard openedInfo.st_mode & S_IFMT == S_IFDIR, openedInfo.st_uid == geteuid() else {
            return
        }

        try afterOpeningArtifact?(name)
        guard nameStillReferences(parentFD: parentFD, name: name, info: openedInfo) else { return }

        for (leafName, kind) in leaves {
            try deleteKnownLeaf(
                parentFD: directoryFD,
                name: leafName,
                kind: kind,
                logicalPath: "\(name)/\(leafName)",
                afterOpeningArtifact: afterOpeningArtifact
            )
        }

        guard nameStillReferences(parentFD: parentFD, name: name, info: openedInfo) else { return }
        if unlinkat(parentFD, name, AT_REMOVEDIR) != 0, errno != ENOTEMPTY, errno != ENOENT {
            throw SecureHostStateError.systemCall("unlinkat \(name)", errno)
        }
    }

    private static func deleteKnownLeaf(
        parentFD: Int32,
        name: String,
        kind: ArtifactKind,
        logicalPath: String,
        afterOpeningArtifact: ((String) throws -> Void)?
    ) throws {
        var originalInfo = stat()
        if fstatat(parentFD, name, &originalInfo, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw SecureHostStateError.systemCall("fstatat \(logicalPath)", errno)
        }
        guard originalInfo.st_uid == geteuid() else { return }

        switch kind {
        case .regularFile:
            guard originalInfo.st_mode & S_IFMT == S_IFREG else { return }
            let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 {
                if errno == ENOENT || errno == ELOOP { return }
                throw SecureHostStateError.systemCall("openat \(logicalPath)", errno)
            }
            defer { close(fd) }

            var openedInfo = stat()
            guard fstat(fd, &openedInfo) == 0 else {
                throw SecureHostStateError.systemCall("fstat \(logicalPath)", errno)
            }
            guard sameObject(originalInfo, openedInfo) else { return }
        case .nixStoreSymlink:
            guard originalInfo.st_mode & S_IFMT == S_IFLNK,
                  let target = symlinkTarget(parentFD: parentFD, name: name),
                  target.hasPrefix("/nix/store/")
            else {
                return
            }
        }

        try afterOpeningArtifact?(logicalPath)
        guard nameStillReferences(parentFD: parentFD, name: name, info: originalInfo) else { return }
        if unlinkat(parentFD, name, 0) != 0, errno != ENOENT {
            throw SecureHostStateError.systemCall("unlinkat \(logicalPath)", errno)
        }
    }

    private static func nameStillReferences(parentFD: Int32, name: String, info: stat) -> Bool {
        var currentInfo = stat()
        return fstatat(parentFD, name, &currentInfo, AT_SYMLINK_NOFOLLOW) == 0
            && sameObject(info, currentInfo)
    }

    private static func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func symlinkTarget(parentFD: Int32, name: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            readlinkat(parentFD, name, pointer.baseAddress, pointer.count - 1)
        }
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}
