import ArgumentParser
import Foundation

public struct SSH: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Connect to the virtual machine via SSH"
    )

    @Argument(help: "Additional arguments to pass to ssh")
    var extraArgs: [String] = []

    @Option(name: .long, help: "State directory for VM data (default: ~/.local/share/darwin-vz-nix)")
    var stateDir: String?

    public init() {}

    public mutating func run() async throws {
        let stateDirectory = stateDir.map { URL(fileURLWithPath: $0) } ?? VMConfig.defaultStateDirectory
        let pidFileURL = stateDirectory.appendingPathComponent("vm.pid")

        let observedGeneration = Status.pidFileGeneration(at: pidFileURL)
        let record = VMManager.readPIDRecord(from: pidFileURL)
        guard Self.recordedVMIsRunning(record, pidFileURL: pidFileURL) else {
            Status.cleanupStoppedRuntimeFiles(in: stateDirectory, observedGeneration: observedGeneration)
            // Not running is an operational state (exit 3), not a usage error (64).
            try exitOperational("No running VM found. Start a VM first with 'darwin-vz-nix start'.")
        }

        let networkManager = NetworkManager(stateDirectory: stateDirectory)
        try networkManager.connectSSH(extraArgs: extraArgs)
    }

    static func recordedVMIsRunning(_ record: VMProcessRecord?, pidFileURL: URL) -> Bool {
        guard let record else {
            return false
        }

        return VMManager.isProcessRunning(pid: record.pid)
            && VMManager.processMatchesRecord(record, pidFileURL: pidFileURL)
    }
}
