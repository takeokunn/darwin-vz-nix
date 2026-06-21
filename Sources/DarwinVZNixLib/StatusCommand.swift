import ArgumentParser
import Foundation

struct VMStatusOutput: Codable {
    let running: Bool
    let pid: Int32?
    let stateDirectory: String
}

public struct Status: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Show the status of the virtual machine"
    )

    @Flag(name: .long, help: "Output status in JSON format")
    var json: Bool = false

    @Option(name: .long, help: "State directory for VM data (default: ~/.local/share/darwin-vz-nix)")
    var stateDir: String?

    public init() {}

    public mutating func run() async throws {
        let stateDirectory = stateDir.map { URL(fileURLWithPath: $0) } ?? VMConfig.defaultStateDirectory
        let pidFileURL = stateDirectory.appendingPathComponent("vm.pid")

        let hasPIDFile = FileManager.default.fileExists(atPath: pidFileURL.path)
        let record = VMManager.readPIDRecord(from: pidFileURL)
        let pid = record?.pid
        let isRunning = record.map {
            VMManager.isProcessRunning(pid: $0.pid)
                && VMManager.processMatchesRecord(pid: $0.pid, expectedExecutablePath: $0.executablePath)
        } ?? false
        if (record != nil && !isRunning) || (record == nil && hasPIDFile) {
            Status.cleanupStoppedRuntimeFiles(in: stateDirectory)
        }

        if json {
            let statusOutput = VMStatusOutput(
                running: isRunning,
                pid: isRunning ? pid : nil,
                stateDirectory: stateDirectory.path
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Propagate encode failures rather than silently printing nothing:
            // scripts consuming --json must be able to tell success from failure.
            let data = try encoder.encode(statusOutput)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            if isRunning, let pid {
                print("VM Status: Running")
                print("PID: \(pid)")
            } else {
                print("VM Status: Stopped")
                if pid != nil, !isRunning {
                    try? FileManager.default.removeItem(at: pidFileURL)
                }
            }
            print("State Directory: \(stateDirectory.path)")
        }
    }

    static func cleanupStoppedRuntimeFiles(in stateDirectory: URL) {
        try? FileManager.default.removeItem(at: stateDirectory.appendingPathComponent("vm.pid"))
        try? FileManager.default.removeItem(at: stateDirectory.appendingPathComponent("guest-ip"))
    }
}
