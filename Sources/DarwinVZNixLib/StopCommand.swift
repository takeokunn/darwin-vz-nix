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

        guard let pid = VMManager.readPID(from: pidFileURL) else {
            throw CleanExit.message("No running VM found (PID file not found).")
        }

        guard VMManager.isProcessRunning(pid: pid) else {
            try? FileManager.default.removeItem(at: pidFileURL)
            throw CleanExit.message("No running VM found (stale PID file cleaned up).")
        }

        let stopped = try VMManager.terminateProcess(pid: pid, pidFileURL: pidFileURL, force: force)
        if !stopped {
            throw VMManagerError.stopFailed("VM process \(pid) could not be stopped.")
        }

        // Clean up state files after stop
        let guestIPFileURL = stateDirectory.appendingPathComponent("guest-ip")
        try? FileManager.default.removeItem(at: guestIPFileURL)
    }
}
