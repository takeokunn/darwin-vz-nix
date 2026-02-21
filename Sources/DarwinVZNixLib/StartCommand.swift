import ArgumentParser
import Foundation

public struct Start: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
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

    @Flag(name: .long, help: "Show VM console output on stderr")
    var verbose: Bool = false

    public init() {}

    public mutating func run() async throws {
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

        // Prevent double-start: check PID file before any setup
        if let existingPID = VMManager.readPID(from: config.pidFileURL),
           VMManager.isProcessRunning(pid: existingPID)
        {
            throw ValidationError(
                "A VM is already running (PID: \(existingPID)). Stop it first with 'darwin-vz-nix stop'."
            )
        }

        try config.validate()
        try config.ensureStateDirectory()

        let networkManager = NetworkManager(stateDirectory: config.stateDirectory)
        try networkManager.ensureSSHKeys()

        let vmManager = VMManager(config: config, verbose: verbose)

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
                    try await vmManager.stop(force: false)
                } catch {
                    fputs("Warning: Graceful shutdown failed: \(error.localizedDescription)\n", stderr)
                }
                Darwin.exit(0)
            }
        }
        sigtermSource.resume()

        Self.cleanStaleLockFiles()

        fputs("Starting NixOS VM (cores: \(cores), memory: \(memory)MB, disk: \(diskSize))...\n", stderr)

        let vmStartTime = Date()
        try await vmManager.start()

        // Discover guest IP via DHCP lease polling
        fputs("Waiting for guest IP address...\n", stderr)
        do {
            let guestIP = try await networkManager.discoverGuestIP(notBefore: vmStartTime)
            try networkManager.writeGuestIP(guestIP)
            fputs("Guest IP: \(guestIP)\n", stderr)
        } catch {
            fputs("Warning: Could not discover guest IP: \(error.localizedDescription)\n", stderr)
        }

        fputs("VM is running. Press Ctrl+C to stop.\n", stderr)

        // Suspend this async task indefinitely. The VM runs on its own queue,
        // and lifecycle is managed by signal handlers (SIGINT/SIGTERM) and
        // VZVirtualMachineDelegate callbacks, which call exit().
        // We cannot use dispatchMain() here because AsyncParsableCommand.run()
        // executes on the cooperative thread pool, not the main thread.
        // Using an infinite AsyncStream avoids CheckedContinuation leak warnings.
        let stream = AsyncStream<Void> { _ in }
        for await _ in stream {}
    }

    static func cleanStaleLockFiles() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [
            "-n", "find", "/nix/store",
            "-maxdepth", "1", "-name", "*.lock",
            "-size", "0", "-perm", "600", "-delete",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                fputs("Cleaned stale lock files from /nix/store.\n", stderr)
            } else {
                fputs(
                    "Warning: Could not clean stale lock files in /nix/store. Run: sudo find /nix/store -maxdepth 1 -name '*.lock' -size 0 -perm 600 -delete\n",
                    stderr
                )
            }
        } catch {
            fputs(
                "Warning: Could not clean stale lock files in /nix/store. Run: sudo find /nix/store -maxdepth 1 -name '*.lock' -size 0 -perm 600 -delete\n",
                stderr
            )
        }
    }
}
