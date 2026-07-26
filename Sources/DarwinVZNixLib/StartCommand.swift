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

    @Flag(name: .long, help: "Internal flag used by the launchd service")
    var launchdManaged: Bool = false

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
            idleTimeout: idleTimeout,
            launchdManaged: launchdManaged
        )

        // Invalid configuration (bad cores/memory/disk-size, missing artifacts)
        // is a usage error (64, EX_USAGE) per the documented exit-code contract,
        // not a generic failure (1). Map VMConfigError accordingly so scripts and
        // CI see the same code as ArgumentParser's own parse errors.
        do {
            try config.validate()
        } catch let error as VMConfigError {
            try exitUsage(error.errorDescription ?? "Invalid VM configuration.")
        }

        // A launchd restart after an intentional SIGKILL durably acknowledges the
        // marker and exits successfully, which makes KeepAlive.SuccessfulExit stop retrying.
        // The marker remains until destroy or an explicit manual start cleans it up,
        // so a crash or acknowledgement failure cannot turn into an unintended restart.
        // Manual starts clear a stale marker and proceed normally.
        if try Self.acknowledgeIntentionalStopRestartIfNeeded(config: config) {
            return
        }

        try SecureHostState.ensureAndValidateStateDirectory(config.stateDirectory)
        if !launchdManaged {
            try SecureHostState.clearIntentionalStop(stateDirectory: config.stateDirectory)
        }
        // Serialize stale-state cleanup with all other VM generations. The descriptor
        // remains held for the process lifetime, including disk-image access.
        let lockFD = Self.tryLockStateDirectory(config.stateDirectory)
        guard lockFD >= 0 else {
            try exitOperational(
                "Could not acquire the VM state lock for \(config.stateDirectory.path). "
                    + "Another VM is already starting or running for this state directory."
            )
        }
        Self.heldStateLockFD = lockFD
        try Self.cleanupRuntimeFilesBeforeStart(config: config)

        let networkManager = NetworkManager(stateDirectory: config.stateDirectory)
        try networkManager.ensureSSHKeys()

        let vmManager = VMManager(config: config, verbose: verbose)

        // Both signals funnel into the single shutdown coordinator, which requests
        // a guest power-off and waits for the guest to actually stop before the
        // process exits. We deliberately do NOT call Darwin.exit() here: exiting
        // immediately would kill the in-process VM (and its VirtioFS server) before
        // the guest finishes syncing, risking data loss on every clean stop.
        let (sigintSource, sigtermSource) = try Self.withTerminationSignalsBlocked {
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)

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
            return (sigintSource, sigtermSource)
        }
        _ = (sigintSource, sigtermSource)

        DaemonLogger.vm.info("Starting NixOS VM (cores: \(cores), memory: \(memory)MB, disk: \(diskSize))...")

        let vmStartTime = Date()
        try await vmManager.start()

        // Discover guest IP via DHCP lease polling
        DaemonLogger.vm.info("Waiting for guest IP address...")
        do {
            let guestIP = try await networkManager.discoverGuestIP(notBefore: vmStartTime)
            try networkManager.writeGuestIP(guestIP)
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

    /// Holds the state-directory lock descriptor for the process lifetime so the
    /// `flock` is not released early by the fd being closed.
    private nonisolated(unsafe) static var heldStateLockFD: Int32 = -1

    /// Try to take an exclusive, non-blocking `flock` on `<stateDirectory>/vm.lock`.
    /// Returns the open descriptor on success (caller must keep it open to hold
    /// the lock), or -1 if the lock is already held or the file can't be opened.
    /// Separated from `run()` so the exclusion can be unit-tested.
    static func tryLockStateDirectory(_ stateDirectory: URL) -> Int32 {
        (try? SecureHostState.openAndLockStateDirectory(stateDirectory)) ?? -1
    }

    static func acknowledgeIntentionalStopRestartIfNeeded(config: VMConfig) throws -> Bool {
        guard config.launchdManaged,
              FileManager.default.fileExists(atPath: config.stateDirectory.path),
              let token = try SecureHostState.validatedIntentionalStopToken(
                  stateDirectory: config.stateDirectory
              )
        else {
            return false
        }
        try SecureHostState.acknowledgeIntentionalStop(
            stateDirectory: config.stateDirectory,
            token: token
        )
        return true
    }

    static func withTerminationSignalsBlocked<T>(_ body: () throws -> T) throws -> T {
        var signals = sigset_t()
        sigemptyset(&signals)
        sigaddset(&signals, SIGINT)
        sigaddset(&signals, SIGTERM)
        var previous = sigset_t()
        guard pthread_sigmask(SIG_BLOCK, &signals, &previous) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
        return try body()
    }

    static func cleanupRuntimeFilesBeforeStart(config: VMConfig) throws {
        if let existingRecord = VMManager.readPIDRecord(from: config.pidFileURL) {
            let isRunning = VMManager.isProcessRunning(pid: existingRecord.pid)
            let matchesRecord = VMManager.processMatchesRecord(existingRecord, pidFileURL: config.pidFileURL)
            if isRunning, matchesRecord {
                // Already-running is an operational state (exit 3), not a usage error (64).
                try exitOperational(
                    "A VM is already running (PID: \(existingRecord.pid)). Stop it first with 'darwin-vz-nix stop'."
                )
            }
        }

        try? FileManager.default.removeItem(at: config.pidFileURL)
        try? FileManager.default.removeItem(at: config.guestIPFileURL)
    }
}
