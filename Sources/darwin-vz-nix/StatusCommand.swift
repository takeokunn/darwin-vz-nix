import ArgumentParser
import Foundation

struct VMStatusOutput: Codable {
    let running: Bool
    let pid: Int32?
    let stateDirectory: String
}

extension DarwinVZNix {
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the status of the virtual machine"
        )

        @Flag(name: .long, help: "Output status in JSON format")
        var json: Bool = false

        mutating func run() async throws {
            let stateDirectory = VMConfig.defaultStateDirectory
            let pidFileURL = VMConfig.defaultPIDFileURL

            let pid = VMManager.readPID(from: pidFileURL)
            let isRunning = pid.map { VMManager.isProcessRunning(pid: $0) } ?? false

            if json {
                let statusOutput = VMStatusOutput(
                    running: isRunning,
                    pid: isRunning ? pid : nil,
                    stateDirectory: stateDirectory.path
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                do {
                    let data = try encoder.encode(statusOutput)
                    print(String(data: data, encoding: .utf8) ?? "{}")
                } catch {
                    fputs("Error: Failed to encode status as JSON: \(error.localizedDescription)\n", stderr)
                }
            } else {
                if isRunning, let pid = pid {
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
    }
}
