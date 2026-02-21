import ArgumentParser
import Foundation

extension DarwinVZNix {
    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop a running NixOS virtual machine"
        )

        @Flag(name: .long, help: "Force stop without graceful shutdown")
        var force: Bool = false

        mutating func run() async throws {
            let pidFileURL = VMConfig.defaultPIDFileURL

            guard let pid = VMManager.readPID(from: pidFileURL) else {
                throw CleanExit.message("No running VM found (PID file not found).")
            }

            guard VMManager.isProcessRunning(pid: pid) else {
                try? FileManager.default.removeItem(at: pidFileURL)
                throw CleanExit.message("No running VM found (stale PID file cleaned up).")
            }

            let stopSignal: Int32 = force ? SIGKILL : SIGTERM
            let signalName = force ? "SIGKILL" : "SIGTERM"
            fputs("Sending \(signalName) to VM process (PID: \(pid))...\n", stderr)

            if kill(pid, stopSignal) == 0 {
                fputs("Signal sent. Waiting for VM to stop...\n", stderr)

                // Wait for process to exit: 2s for SIGKILL, 30s for SIGTERM
                let maxWait: UInt32 = force ? 2_000_000 : 30_000_000
                var waited: UInt32 = 0
                while VMManager.isProcessRunning(pid: pid), waited < maxWait {
                    usleep(100_000) // 100ms
                    waited += 100_000
                }

                if VMManager.isProcessRunning(pid: pid) {
                    fputs("Warning: Process \(pid) still running after \(signalName).\n", stderr)
                } else {
                    fputs("VM stopped.\n", stderr)
                    // SIGKILL prevents the target from cleaning up, so we do it here
                    if force {
                        try? FileManager.default.removeItem(at: pidFileURL)
                    }
                }
            } else {
                let err = String(cString: strerror(errno))
                throw ValidationError("Failed to send signal to PID \(pid): \(err)")
            }
        }
    }
}
