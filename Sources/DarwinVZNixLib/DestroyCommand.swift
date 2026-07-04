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

        // Auto-stop VM if running. Treat reused/dead PID files as stale, but never signal an
        // unrelated process before deleting state.
        if let record = VMManager.readPIDRecord(from: pidFileURL) {
            if VMManager.isProcessRunning(pid: record.pid) {
                if VMManager.processMatchesRecord(
                    pid: record.pid,
                    expectedExecutablePath: record.executablePath
                ) {
                    print("VM is running. Stopping before destroying state...")
                    let stopped = try VMManager.terminateProcess(
                        pid: record.pid,
                        pidFileURL: pidFileURL,
                        expectedExecutablePath: record.executablePath
                    )
                    if !stopped {
                        throw VMManagerError.stopFailed(
                            "VM process \(record.pid) could not be stopped. Aborting destroy."
                        )
                    }
                } else {
                    try? FileManager.default.removeItem(at: pidFileURL)
                    print("Stale PID file removed.")
                }
            } else {
                try? FileManager.default.removeItem(at: pidFileURL)
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
        let lockFD = Start.tryLockStateDirectory(stateDirectory)
        guard lockFD >= 0 else {
            try exitOperational(
                "Could not acquire the VM state lock for \(stateDirectory.path). "
                    + "A VM is still starting or running for this state directory. Aborting destroy."
            )
        }
        defer { close(lockFD) }

        // Delete all known state files and directories. This must cover every
        // artifact any subcommand can create, or `destroy` leaves state behind:
        //   - gcroots/  holds Nix GC roots (nix-store --add-root symlinks) that
        //     pin the guest kernel/initrd/system store paths. Leaving them keeps
        //     those paths un-collectable forever, defeating the point of destroy.
        //   - ssh-pub/  is the public-key-only VirtioFS share directory.
        // vm.lock goes LAST: once it is unlinked, a concurrent `start` can
        // create a fresh lock file and proceed — by then every other artifact
        // must already be gone so that `start` sees a clean slate.
        let itemsToDelete: [URL] = [
            stateDirectory.appendingPathComponent("disk.img"),
            stateDirectory.appendingPathComponent("vm.pid"),
            stateDirectory.appendingPathComponent("console.log"),
            stateDirectory.appendingPathComponent("guest-ip"),
            stateDirectory.appendingPathComponent("ssh", isDirectory: true),
            stateDirectory.appendingPathComponent("ssh-pub", isDirectory: true),
            stateDirectory.appendingPathComponent("gcroots", isDirectory: true),
            stateDirectory.appendingPathComponent("vm.lock"),
        ]

        for url in itemsToDelete {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                // Item does not exist; nothing to delete
            }
        }

        // The docs promise `destroy` removes the entire state directory. Remove
        // it too — via rmdir(2), which only removes an EMPTY directory: a
        // `--state-dir` that (mis)points at a shared directory can never take
        // unrelated files down with it, and unlike a check-then-removeItem
        // sequence this cannot race a concurrent file creation into a recursive
        // delete. A leftover non-darwin-vz-nix file leaves the directory in
        // place, by design.
        _ = rmdir(stateDirectory.path)

        print("VM state destroyed.")
    }
}
