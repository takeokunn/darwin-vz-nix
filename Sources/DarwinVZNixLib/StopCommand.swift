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

        let stopSignal: Int32 = force ? SIGKILL : SIGTERM
        let signalName = force ? "SIGKILL" : "SIGTERM"
        DaemonLogger.vm.info("Sending \(signalName) to VM process (PID: \(pid))...")

        if kill(pid, stopSignal) == 0 {
            DaemonLogger.vm.info("Signal sent. Waiting for VM to stop...")

            // Wait for process to exit: 2s for SIGKILL, 30s for SIGTERM
            let maxWait: UInt32 = force ? 2_000_000 : 30_000_000
            var waited: UInt32 = 0
            while VMManager.isProcessRunning(pid: pid), waited < maxWait {
                usleep(100_000) // 100ms
                waited += 100_000
            }

            if VMManager.isProcessRunning(pid: pid) {
                DaemonLogger.vm.warning("Process did not stop after SIGTERM. Sending SIGKILL...")
                if kill(pid, SIGKILL) == 0 {
                    // Wait up to 2s for SIGKILL to take effect
                    var killWaited: UInt32 = 0
                    while VMManager.isProcessRunning(pid: pid), killWaited < 2_000_000 {
                        usleep(100_000)
                        killWaited += 100_000
                    }
                    if VMManager.isProcessRunning(pid: pid) {
                        DaemonLogger.vm.error("Process \(pid) still running after SIGKILL.")
                    } else {
                        DaemonLogger.vm.info("VM force-stopped after SIGTERM timeout.")
                        try? FileManager.default.removeItem(at: pidFileURL)
                    }
                }
            } else {
                DaemonLogger.vm.info("VM stopped.")
                // SIGKILL prevents the target from cleaning up, so we do it here
                if force {
                    try? FileManager.default.removeItem(at: pidFileURL)
                }
            }
        } else {
            let err = String(cString: strerror(errno))
            throw ValidationError("Failed to send signal to PID \(pid): \(err)")
        }

        // Clean up state files after stop
        let guestIPFileURL = stateDirectory.appendingPathComponent("guest-ip")
        try? FileManager.default.removeItem(at: guestIPFileURL)
    }
}
