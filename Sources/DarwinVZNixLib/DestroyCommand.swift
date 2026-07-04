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

        // Confirm with user before irreversible deletion
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

        // Delete all known state files and directories. This must cover every
        // artifact any subcommand can create, or `destroy` leaves state behind:
        //   - gcroots/  holds Nix GC roots (nix-store --add-root symlinks) that
        //     pin the guest kernel/initrd/system store paths. Leaving them keeps
        //     those paths un-collectable forever, defeating the point of destroy.
        //   - ssh-pub/  is the public-key-only VirtioFS share directory.
        let itemsToDelete: [URL] = [
            stateDirectory.appendingPathComponent("disk.img"),
            stateDirectory.appendingPathComponent("vm.pid"),
            stateDirectory.appendingPathComponent("vm.lock"),
            stateDirectory.appendingPathComponent("console.log"),
            stateDirectory.appendingPathComponent("guest-ip"),
            stateDirectory.appendingPathComponent("ssh", isDirectory: true),
            stateDirectory.appendingPathComponent("ssh-pub", isDirectory: true),
            stateDirectory.appendingPathComponent("gcroots", isDirectory: true),
        ]

        for url in itemsToDelete {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                // Item does not exist; nothing to delete
            }
        }

        // The docs promise `destroy` removes the entire state directory. Remove
        // it too — but ONLY if now empty, so a `--state-dir` that (mis)points at a
        // shared directory can never take unrelated files down with it. A leftover
        // non-darwin-vz-nix file leaves the directory in place, by design.
        if let remaining = try? FileManager.default.contentsOfDirectory(atPath: stateDirectory.path),
           remaining.isEmpty
        {
            try? FileManager.default.removeItem(at: stateDirectory)
        }

        print("VM state destroyed.")
    }
}
