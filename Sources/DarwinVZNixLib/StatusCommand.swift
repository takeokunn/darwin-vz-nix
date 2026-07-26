import ArgumentParser
import Foundation

struct VMStatusOutput: Codable {
    let running: Bool
    let pid: Int32?
    let stateDirectory: String
}

struct RuntimePIDFileGeneration: Equatable {
    let device: dev_t
    let inode: ino_t
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

        let observedGeneration = Status.pidFileGeneration(at: pidFileURL)
        let hasPIDFile = observedGeneration != nil
        let record = VMManager.readPIDRecord(from: pidFileURL)
        let pid = record?.pid
        let isRunning = record.map {
            VMManager.isProcessRunning(pid: $0.pid)
                && VMManager.processMatchesRecord($0, pidFileURL: pidFileURL)
        } ?? false
        if (record != nil && !isRunning) || (record == nil && hasPIDFile) {
            Status.cleanupStoppedRuntimeFiles(in: stateDirectory, observedGeneration: observedGeneration)
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
            }
            print("State Directory: \(stateDirectory.path)")
        }
    }

    static func pidFileGeneration(at url: URL) -> RuntimePIDFileGeneration? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        return RuntimePIDFileGeneration(device: metadata.st_dev, inode: metadata.st_ino)
    }

    @discardableResult
    static func cleanupStoppedRuntimeFiles(
        in stateDirectory: URL,
        observedGeneration: RuntimePIDFileGeneration?,
        beforeLock: (() -> Void)? = nil
    ) -> Bool {
        let pidFileURL = stateDirectory.appendingPathComponent("vm.pid")
        beforeLock?()
        guard let lockFD = try? SecureHostState.openAndLockStateDirectory(stateDirectory) else { return false }
        defer { close(lockFD) }
        guard pidFileGeneration(at: pidFileURL) == observedGeneration else { return false }
        try? FileManager.default.removeItem(at: pidFileURL)
        try? FileManager.default.removeItem(at: stateDirectory.appendingPathComponent("guest-ip"))
        return true
    }
}
