import ArgumentParser
import Foundation

public struct Start: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Start a NixOS virtual machine",
        discussion: """
        Boots a NixOS guest using macOS Virtualization.framework. The kernel, initrd, and \
        system are aarch64-linux artifacts you build or fetch first:

          nix run .#build-guest-artifacts

        That writes ./result-kernel/Image, ./result-initrd/initrd, and ./result-system, then:

          darwin-vz-nix start --kernel ./result-kernel/Image --initrd ./result-initrd/initrd --system ./result-system

        The VM runs in the foreground; press Ctrl+C (or run 'darwin-vz-nix stop') to shut it \
        down gracefully. Connect with 'darwin-vz-nix ssh' once it reports a guest IP.
        """
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

    @Option(name: .long, help: "State directory for VM data (default: ~/.local/share/darwin-vz-nix)")
    var stateDir: String?

    public init() {}

    public mutating func run() async throws {
        let config = VMConfig(
            cores: cores,
            memory: memory,
            diskSize: diskSize,
            kernelURL: URL(fileURLWithPath: kernel),
            initrdURL: URL(fileURLWithPath: initrd),
            systemURL: system.map { URL(fileURLWithPath: $0) },
            stateDirectory: stateDir.map { URL(fileURLWithPath: $0) },
            rosetta: rosetta,
            shareNixStore: shareNixStore,
            idleTimeout: idleTimeout
        )

        try Self.cleanupRuntimeFilesBeforeStart(config: config)

        // Invalid configuration (bad cores/memory/disk-size, missing artifacts)
        // is a usage error (64, EX_USAGE) per the documented exit-code contract,
        // not a generic failure (1). Map VMConfigError accordingly so scripts and
        // CI see the same code as ArgumentParser's own parse errors.
        do {
            try config.validate()
        } catch let error as VMConfigError {
            try exitUsage(error.errorDescription ?? "Invalid VM configuration.")
        }
        try config.ensureStateDirectory()

        let networkManager = NetworkManager(stateDirectory: config.stateDirectory)
        try networkManager.ensureSSHKeys()

        let vmManager = VMManager(config: config, verbose: verbose)

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        // Both signals funnel into the single shutdown coordinator, which requests
        // a guest power-off and waits for the guest to actually stop before the
        // process exits. We deliberately do NOT call Darwin.exit() here: exiting
        // immediately would kill the in-process VM (and its VirtioFS server) before
        // the guest finishes syncing, risking data loss on every clean stop.
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            DaemonLogger.vm.info("Received SIGINT, shutting down VM...")
            vmManager.beginGracefulShutdown(exitCode: 0)
        }
        sigintSource.resume()

        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource.setEventHandler {
            DaemonLogger.vm.info("Received SIGTERM, shutting down VM...")
            vmManager.beginGracefulShutdown(exitCode: 0)
        }
        sigtermSource.resume()

        DaemonLogger.vm.info("Starting NixOS VM (cores: \(cores), memory: \(memory)MB, disk: \(diskSize))...")

        let vmStartTime = Date()
        try await vmManager.start()

        // Discover guest IP via DHCP lease polling
        DaemonLogger.vm.info("Waiting for guest IP address...")
        do {
            let guestIP = try await networkManager.discoverGuestIP(notBefore: vmStartTime)
            try networkManager.writeGuestIP(guestIP)
            NetworkManager.scrubUserKnownHosts(ip: guestIP)
            DaemonLogger.vm.info("Guest IP: \(guestIP)")
        } catch {
            DaemonLogger.vm.warning("Could not discover guest IP: \(error.localizedDescription)")
            DaemonLogger.vm.warning("VM is running but unreachable via SSH. Run `darwin-vz-nix doctor` for host-side diagnostics.")
        }

        DaemonLogger.vm.info("VM is running. Press Ctrl+C to stop.")

        // Suspend this async task indefinitely. The VM runs on its own queue,
        // and lifecycle is managed by signal handlers (SIGINT/SIGTERM) and
        // VZVirtualMachineDelegate callbacks, which call exit().
        // We cannot use dispatchMain() here because AsyncParsableCommand.run()
        // executes on the cooperative thread pool, not the main thread.
        // Using an infinite AsyncStream avoids CheckedContinuation leak warnings.
        let stream = AsyncStream<Void> { _ in }
        for await _ in stream {}
    }

    static func cleanupRuntimeFilesBeforeStart(config: VMConfig) throws {
        if let existingRecord = VMManager.readPIDRecord(from: config.pidFileURL) {
            let isRunning = VMManager.isProcessRunning(pid: existingRecord.pid)
            let matchesRecord = VMManager.processMatchesRecord(
                pid: existingRecord.pid,
                expectedExecutablePath: existingRecord.executablePath
            )
            if isRunning, matchesRecord {
                // Already-running is an operational state (exit 3), not a usage error (64).
                try exitOperational(
                    "A VM is already running (PID: \(existingRecord.pid)). Stop it first with 'darwin-vz-nix stop'."
                )
            }
        }

        Status.cleanupStoppedRuntimeFiles(in: config.stateDirectory)
    }
}
