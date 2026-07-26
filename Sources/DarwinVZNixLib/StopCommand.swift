import ArgumentParser
import Foundation

public struct Stop: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Stop a running NixOS virtual machine"
    )

    @Flag(name: .long, help: "Force stop without graceful shutdown")
    var force: Bool = false

    @Option(name: .long, help: "State directory for VM data (default: ~/.local/share/darwin-vz-nix)")
    var stateDir: String?

    public init() {}

    public mutating func run() async throws {
        let stateDirectory = stateDir.map { URL(fileURLWithPath: $0) } ?? VMConfig.defaultStateDirectory
        let pidFileURL = stateDirectory.appendingPathComponent("vm.pid")

        var stateMetadata = stat()
        if lstat(stateDirectory.path, &stateMetadata) != 0, errno == ENOENT {
            throw CleanExit.message("No running VM found (PID file not found).")
        }
        try SecureHostState.ensureAndValidateStateDirectory(stateDirectory, create: false)

        let observedGeneration = Status.pidFileGeneration(at: pidFileURL)
        guard let record = VMManager.readPIDRecord(from: pidFileURL) else {
            Status.cleanupStoppedRuntimeFiles(in: stateDirectory, observedGeneration: observedGeneration)
            throw CleanExit.message("No running VM found (PID file not found).")
        }

        guard VMManager.isProcessRunning(pid: record.pid) else {
            Status.cleanupStoppedRuntimeFiles(in: stateDirectory, observedGeneration: observedGeneration)
            throw CleanExit.message("No running VM found (stale PID file cleaned up).")
        }

        guard VMManager.processMatchesRecord(record, pidFileURL: pidFileURL) else {
            Status.cleanupStoppedRuntimeFiles(in: stateDirectory, observedGeneration: observedGeneration)
            throw CleanExit.message("No running VM found (PID belongs to another process).")
        }

        if record.launchdManaged {
            _ = try SecureHostState.markIntentionalStop(stateDirectory: stateDirectory, pid: record.pid)
        }
        let termination: VMProcessTerminationResult
        do {
            termination = try VMManager.terminateProcess(
                pid: record.pid,
                pidFileURL: pidFileURL,
                force: force
            )
        } catch {
            if record.launchdManaged {
                try? SecureHostState.clearIntentionalStop(stateDirectory: stateDirectory)
            }
            throw error
        }
        if !termination.stopped {
            if record.launchdManaged {
                try? SecureHostState.clearIntentionalStop(stateDirectory: stateDirectory)
            }
            throw VMManagerError.stopFailed("VM process \(record.pid) could not be stopped.")
        }
        // Clean up state files after stop
        Status.cleanupStoppedRuntimeFiles(in: stateDirectory, observedGeneration: observedGeneration)
    }
}
