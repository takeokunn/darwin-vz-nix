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

        guard let pid = VMManager.readPID(from: pidFileURL),
              VMManager.isProcessRunning(pid: pid)
        else {
            throw ValidationError("No running VM found. Start a VM first with 'darwin-vz-nix start'.")
        }

        let networkManager = NetworkManager(stateDirectory: stateDirectory)
        try networkManager.connectSSH(extraArgs: extraArgs)
    }
}
