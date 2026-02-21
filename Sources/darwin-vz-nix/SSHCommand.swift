import ArgumentParser
import Foundation

extension DarwinVZNix {
    struct SSH: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Connect to the virtual machine via SSH"
        )

        @Argument(help: "Additional arguments to pass to ssh")
        var extraArgs: [String] = []

        mutating func run() async throws {
            let stateDirectory = VMConfig.defaultStateDirectory
            let pidFileURL = VMConfig.defaultPIDFileURL

            guard let pid = VMManager.readPID(from: pidFileURL),
                  VMManager.isProcessRunning(pid: pid)
            else {
                throw ValidationError("No running VM found. Start a VM first with 'darwin-vz-nix start'.")
            }

            let networkManager = NetworkManager(stateDirectory: stateDirectory)
            try networkManager.connectSSH(extraArgs: extraArgs)
        }
    }
}
