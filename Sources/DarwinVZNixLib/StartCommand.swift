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

        // Take an exclusive, process-lifetime lock on the state directory before
        // touching the disk image. The PID-file guard above is check-then-act
        // and the PID file is not written until much later, so two `start` runs
        // racing on the same --state-dir could both open disk.img read-write and
        // corrupt the guest filesystem. flock closes that window; the descriptor
        // is held for the process lifetime and released automatically on exit.
        let lockFD = Self.tryLockStateDirectory(config.stateDirectory)
        guard lockFD >= 0 else {
            try exitOperational(
                "Could not acquire the VM state lock for \(config.stateDirectory.path). "
                    + "Another VM is already starting or running for this state directory."
            )
        }
        Self.heldStateLockFD = lockFD

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
            // Evict stale host-key pins ONCE per boot, right after the IP is
            // known. `ssh` connections during this boot then re-pin via
            // accept-new and keep verifying against that pin; scrubbing any
            // later (e.g. per connection) would defeat host-key pinning.
            networkManager.scrubStateKnownHosts(ip: guestIP)
            NetworkManager.scrubUserKnownHosts()
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
        let lockPath = stateDirectory.appendingPathComponent("vm.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return -1 }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return -1
        }
        return fd
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
