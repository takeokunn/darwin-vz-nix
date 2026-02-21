import ArgumentParser
import Foundation

struct VMStatusOutput: Codable {
    let running: Bool
    let pid: Int32?
    let stateDirectory: String
}

enum Constants {
    static let defaultSSHPort: UInt16 = 31122
}

@main
struct DarwinVZNix: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "darwin-vz-nix",
        abstract: "Manage NixOS Linux VMs using macOS Virtualization.framework",
        subcommands: [Start.self, Stop.self, Status.self, SSH.self]
    )
}

// MARK: - Start Subcommand

extension DarwinVZNix {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start a NixOS virtual machine"
        )

        @Option(name: .long, help: "Number of CPU cores (default: 4)")
        var cores: Int = 4

        @Option(name: .long, help: "Memory in MB (default: 8192)")
        var memory: UInt64 = 8192

        @Option(name: .long, help: "Disk size (e.g. 100G, 512M) (default: 100G)")
        var diskSize: String = "100G"

        @Option(name: .long, help: "Path to kernel image")
        var kernel: String

        @Option(name: .long, help: "Path to initrd image")
        var initrd: String

        @Option(name: .long, help: "Path to NixOS system toplevel (passed as init= kernel parameter)")
        var system: String?

        @Flag(name: .long, inversion: .prefixedNo, help: "Enable Rosetta 2 for x86_64 support (default: true)")
        var rosetta: Bool = true

        @Flag(name: .long, inversion: .prefixedNo, help: "Share host /nix/store via VirtioFS (default: true)")
        var shareNixStore: Bool = true

        @Option(name: .long, help: "Idle timeout in minutes (0 = disabled, default: 0)")
        var idleTimeout: Int = 0

        mutating func run() async throws {
            let config = VMConfig(
                cores: cores,
                memory: memory,
                diskSize: diskSize,
                kernelURL: URL(fileURLWithPath: kernel),
                initrdURL: URL(fileURLWithPath: initrd),
                systemURL: system.map { URL(fileURLWithPath: $0) },
                rosetta: rosetta,
                shareNixStore: shareNixStore,
                idleTimeout: idleTimeout
            )

            try config.validate()
            try config.ensureStateDirectory()

            let networkManager = NetworkManager(stateDirectory: config.stateDirectory)
            try networkManager.ensureSSHKeys()

            let vmManager = VMManager(config: config)

            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)

            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigintSource.setEventHandler {
                fputs("\nReceived SIGINT, shutting down VM...\n", stderr)
                Task {
                    do {
                        try await vmManager.stop(force: false)
                    } catch {
                        fputs("Warning: Graceful shutdown failed: \(error.localizedDescription)\n", stderr)
                    }
                    Darwin.exit(0)
                }
            }
            sigintSource.resume()

            let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            sigtermSource.setEventHandler {
                fputs("\nReceived SIGTERM, shutting down VM...\n", stderr)
                Task {
                    do {
                        try await vmManager.stop(force: true)
                    } catch {
                        fputs("Warning: Force shutdown failed: \(error.localizedDescription)\n", stderr)
                    }
                    Darwin.exit(0)
                }
            }
            sigtermSource.resume()

            fputs("Starting NixOS VM (cores: \(cores), memory: \(memory)MB, disk: \(diskSize))...\n", stderr)

            try await vmManager.start()

            fputs("VM is running. Press Ctrl+C to stop.\n", stderr)

            // Suspend this async task indefinitely. The VM runs on its own queue,
            // and lifecycle is managed by signal handlers (SIGINT/SIGTERM) and
            // VZVirtualMachineDelegate callbacks, which call exit().
            // We cannot use dispatchMain() here because AsyncParsableCommand.run()
            // executes on the cooperative thread pool, not the main thread.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
    }
}

// MARK: - Stop Subcommand

extension DarwinVZNix {
    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop a running NixOS virtual machine"
        )

        @Flag(name: .long, help: "Force stop without graceful shutdown")
        var force: Bool = false

        mutating func run() async throws {
            let stateDirectory = VMConfig.defaultStateDirectory
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
            fputs("Sending \(signalName) to VM process (PID: \(pid))...\n", stderr)

            if kill(pid, stopSignal) == 0 {
                fputs("Signal sent successfully.\n", stderr)
            } else {
                let err = String(cString: strerror(errno))
                throw ValidationError("Failed to send signal to PID \(pid): \(err)")
            }
        }
    }
}

// MARK: - Status Subcommand

extension DarwinVZNix {
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the status of the virtual machine"
        )

        @Flag(name: .long, help: "Output status in JSON format")
        var json: Bool = false

        mutating func run() async throws {
            let stateDirectory = VMConfig.defaultStateDirectory
            let pidFileURL = stateDirectory.appendingPathComponent("vm.pid")

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

// MARK: - SSH Subcommand

extension DarwinVZNix {
    struct SSH: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Connect to the virtual machine via SSH"
        )

        @Option(name: .long, help: "SSH port (default: \(Constants.defaultSSHPort))")
        var port: UInt16 = Constants.defaultSSHPort

        @Argument(help: "Additional arguments to pass to ssh")
        var extraArgs: [String] = []

        mutating func run() async throws {
            let stateDirectory = VMConfig.defaultStateDirectory
            let pidFileURL = stateDirectory.appendingPathComponent("vm.pid")

            guard let pid = VMManager.readPID(from: pidFileURL),
                  VMManager.isProcessRunning(pid: pid)
            else {
                throw ValidationError("No running VM found. Start a VM first with 'darwin-vz-nix start'.")
            }

            let networkManager = NetworkManager(stateDirectory: stateDirectory)
            try networkManager.connectSSH(port: port, extraArgs: extraArgs)
        }
    }
}
