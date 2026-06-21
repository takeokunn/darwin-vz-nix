import Foundation
@preconcurrency import Virtualization

struct VMProcessRecord: Codable, Equatable {
    let pid: Int32
    let executablePath: String?
    let stateDirectory: String
    let startedAt: Date
}

enum VMManagerError: LocalizedError {
    case vmNotRunning
    case vmAlreadyRunning
    case diskImageCreationFailed(String)
    case pidFileWriteFailed(String)
    case startFailed(String)
    case stopFailed(String)
    case configurationInvalid(String)

    var errorDescription: String? {
        switch self {
        case .vmNotRunning:
            "No virtual machine is currently running."
        case .vmAlreadyRunning:
            "A virtual machine is already running."
        case let .diskImageCreationFailed(reason):
            "Failed to create disk image: \(reason)"
        case let .pidFileWriteFailed(reason):
            "Failed to write PID file: \(reason)"
        case let .startFailed(reason):
            "Failed to start virtual machine: \(reason)"
        case let .stopFailed(reason):
            "Failed to stop virtual machine: \(reason)"
        case let .configurationInvalid(reason):
            "Invalid VM configuration: \(reason)"
        }
    }
}

class VMManager: NSObject, VZVirtualMachineDelegate {
    private var virtualMachine: VZVirtualMachine?
    private let config: VMConfig
    private let queue = DispatchQueue(label: "com.darwin-vz-nix.vm")
    private let idleTimeoutMinutes: Int
    private let verbose: Bool
    private var consolePipe: Pipe?
    private var consoleLogHandle: FileHandle?
    private var idleMonitor: IdleMonitor?

    // Shutdown coordination. All of these are read/written only on `queue`.
    private var isShuttingDown = false
    private var didFinalize = false

    init(config: VMConfig, verbose: Bool = false) {
        self.config = config
        idleTimeoutMinutes = config.idleTimeout
        self.verbose = verbose
        super.init()
    }

    // MARK: - VM Configuration

    func createVMConfiguration() throws -> VZVirtualMachineConfiguration {
        let vmConfig = VZVirtualMachineConfiguration()

        // Boot loader.
        // NOTE: deliberately no `root=` parameter. The NixOS guest uses a
        // systemd-initrd whose generated fstab already defines the root mount
        // (/dev/vda, with x-systemd.makefs/growfs). Passing `root=/dev/vda` as
        // well makes systemd-fstab-generator try to create sysroot.mount twice
        // and fail (exit 1), which silently breaks makefs (the disk is never
        // formatted), the rw remount, and overlay setup — dropping the guest to
        // emergency mode. Letting the initrd own the root mount fixes all of it.
        let bootLoader = VZLinuxBootLoader(kernelURL: config.kernelURL)
        bootLoader.initialRamdiskURL = config.initrdURL
        var cmdline = "console=hvc0"
        if let systemURL = config.systemURL {
            cmdline += " init=\(systemURL.path)/init"
        }
        bootLoader.commandLine = cmdline
        vmConfig.bootLoader = bootLoader

        // CPU & Memory
        let coreCount = max(
            VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            min(config.cores, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        )
        vmConfig.cpuCount = coreCount

        let memoryBytes = UInt64(config.memory) * 1024 * 1024
        let memorySize = max(
            VZVirtualMachineConfiguration.minimumAllowedMemorySize,
            min(memoryBytes, VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        )
        vmConfig.memorySize = memorySize

        // Storage (VirtioBlock)
        let diskURL = config.diskImageURL
        guard FileManager.default.fileExists(atPath: diskURL.path) else {
            throw VMManagerError.diskImageCreationFailed(
                "Disk image not found at \(diskURL.path). Run 'start' first."
            )
        }
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: diskURL,
            readOnly: false
        )
        let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
        vmConfig.storageDevices = [blockDevice]

        // Network (NAT) with a deterministic per-state-directory MAC so multiple
        // VMs don't collide on the shared NAT segment during DHCP/ARP discovery.
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        if let mac = VZMACAddress(string: config.macAddress) {
            networkDevice.macAddress = mac
        }
        vmConfig.networkDevices = [networkDevice]

        // Entropy
        vmConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Memory balloon: lets the host reclaim unused guest memory, which matters
        // for a long-lived builder that may spike during heavy builds.
        vmConfig.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // Serial console — write to console.log file and optionally tee to stderr
        FileManager.default.createFile(atPath: config.consoleLogURL.path, contents: nil)
        let consoleLogHandle = try FileHandle(forWritingTo: config.consoleLogURL)
        // Retain for a clean flush/close during shutdown.
        self.consoleLogHandle = consoleLogHandle

        let consoleWriteHandle: FileHandle
        if verbose {
            let pipe = Pipe()
            consolePipe = pipe
            consoleWriteHandle = pipe.fileHandleForWriting
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    consoleLogHandle.write(data)
                    let sanitized = VMManager.stripTerminalRequests(data)
                    if !sanitized.isEmpty {
                        FileHandle.standardError.write(sanitized)
                    }
                }
            }
        } else {
            consoleWriteHandle = consoleLogHandle
        }

        // Always use /dev/null for serial console input.
        // The host terminal responds to escape sequences in boot output (DSR etc.),
        // and those responses leak into the guest's stdin, corrupting shell input.
        // Console is view-only; interactive access is via SSH.
        guard let consoleReadHandle = FileHandle(forReadingAtPath: "/dev/null") else {
            throw VMManagerError.configurationInvalid("Could not open /dev/null for serial console input.")
        }

        let serialPortAttachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: consoleReadHandle,
            fileHandleForWriting: consoleWriteHandle
        )
        let serialPortConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialPortConfig.attachment = serialPortAttachment
        vmConfig.serialPorts = [serialPortConfig]

        // VirtioFS: /nix/store sharing
        var directoryShares: [VZDirectorySharingDeviceConfiguration] = []

        if config.shareNixStore {
            let nixStoreShare = try VirtioFSManager.createNixStoreShare()
            directoryShares.append(nixStoreShare)
        }

        // VirtioFS: Rosetta 2
        if config.rosetta {
            if let rosettaShare = try VirtioFSManager.createRosettaShare() {
                directoryShares.append(rosettaShare)
            }
        }

        // VirtioFS: SSH public key only (never the private key — the guest is untrusted)
        let sshKeysShare = try VirtioFSManager.createSSHKeysShare(
            sshDirectory: config.sshDirectory,
            shareDirectory: config.sshPublicShareDirectory
        )
        directoryShares.append(sshKeysShare)

        vmConfig.directorySharingDevices = directoryShares

        // Validate the configuration. Preserve the NSError domain/code so the
        // underlying Virtualization.framework reason isn't flattened to a string.
        do {
            try vmConfig.validate()
        } catch {
            let nsError = error as NSError
            throw VMManagerError.configurationInvalid(
                "\(error.localizedDescription) [\(nsError.domain) code \(nsError.code)]"
            )
        }

        return vmConfig
    }

    // MARK: - VM Lifecycle

    func start() async throws {
        guard virtualMachine == nil else {
            throw VMManagerError.vmAlreadyRunning
        }

        try config.ensureStateDirectory()
        try ensureDiskImage()

        let vmConfig = try createVMConfiguration()

        let vm = VZVirtualMachine(configuration: vmConfig, queue: queue)
        vm.delegate = self
        virtualMachine = vm

        try await withPIDFile {
            // VZVirtualMachine requires all operations on the queue specified in init.
            // Swift async/await runs on the cooperative thread pool, which is NOT the VM's queue.
            // We must dispatch start() to the VM's DispatchQueue explicitly.
            nonisolated(unsafe) let vmRef = vm
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    vmRef.start { result in
                        switch result {
                        case .success:
                            continuation.resume()
                        case let .failure(error):
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }

        if idleTimeoutMinutes > 0 {
            let monitor = IdleMonitor(
                timeoutMinutes: idleTimeoutMinutes,
                guestIPFileURL: config.guestIPFileURL,
                onIdleShutdown: { [weak self] in
                    guard let self else { return }
                    DaemonLogger.idle.warning("VM idle for \(idleTimeoutMinutes) minute(s). Shutting down automatically.")
                    beginGracefulShutdown(exitCode: 0)
                }
            )
            monitor.start()
            queue.sync { idleMonitor = monitor }
        }
    }

    /// Begin a graceful shutdown of the in-process VM.
    ///
    /// Sends an ACPI power-button request to the guest and then *waits* for the
    /// guest OS to actually power off — reported via the `guestDidStop` /
    /// `didStopWithError` delegate callbacks — before exiting the host process.
    /// This is the critical difference from a naive stop: the in-process VM (and
    /// its VirtioFS server) must outlive the guest's filesystem sync/unmount, or
    /// the guest's `/nix/store` writes can be lost on every "clean" stop.
    ///
    /// A timeout fallback forces termination if the guest never reports stopping.
    /// Idempotent and safe to call from any thread and from multiple sources
    /// (SIGINT/SIGTERM handlers, the idle monitor). All shutdown state is
    /// confined to `queue`.
    func beginGracefulShutdown(exitCode: Int32 = 0) {
        queue.async { [weak self] in
            guard let self else { return }
            if isShuttingDown { return }
            isShuttingDown = true

            idleMonitor?.stop()
            idleMonitor = nil

            guard let vm = virtualMachine else {
                // VM never came up (or already torn down): exit cleanly now.
                finalizeShutdown(exitCode: exitCode)
                return
            }

            DaemonLogger.vm.info(
                "Requesting guest power-off; waiting up to \(Constants.gracefulStopTimeoutSeconds)s for a clean shutdown..."
            )
            do {
                try vm.requestStop()
                // If the guest never reports stopping, force-exit after the timeout.
                // `finalizeShutdown` is idempotent, so a later `guestDidStop` is harmless.
                queue.asyncAfter(deadline: .now() + .seconds(Constants.gracefulStopTimeoutSeconds)) { [weak self] in
                    guard let self, !didFinalize else { return }
                    DaemonLogger.vm.warning(
                        "Guest did not power off within \(Constants.gracefulStopTimeoutSeconds)s; forcing shutdown."
                    )
                    finalizeShutdown(exitCode: exitCode)
                }
            } catch {
                DaemonLogger.vm.warning("requestStop failed: \(error.localizedDescription). Forcing shutdown.")
                finalizeShutdown(exitCode: exitCode)
            }
        }
    }

    /// The single process-exit funnel. Flushes console output, removes runtime
    /// files, and terminates the process. Must be called on `queue`; idempotent.
    private func finalizeShutdown(exitCode: Int32) {
        if didFinalize { return }
        didFinalize = true

        // Detach the console reader and flush (but do NOT close) the log file.
        // In --verbose mode the readabilityHandler runs on a libdispatch I/O
        // queue and holds its own reference to the handle; setting the handler
        // to nil does not cancel an invocation already in flight, so closing the
        // descriptor here could race a concurrent write() and abort the process.
        // `Darwin.exit()` below reclaims the descriptor; we only synchronize to
        // flush the tail of the log.
        consolePipe?.fileHandleForReading.readabilityHandler = nil
        try? consoleLogHandle?.synchronize()
        consoleLogHandle = nil

        virtualMachine = nil
        removePIDFile()
        removeGuestIPFile()
        DaemonLogger.vm.info("VM stopped.")
        Darwin.exit(exitCode)
    }

    // MARK: - VZVirtualMachineDelegate

    // These callbacks are delivered on the VM's `queue`, so they may call
    // `finalizeShutdown` directly.

    func virtualMachine(_: VZVirtualMachine, didStopWithError error: Error) {
        DaemonLogger.vm.error("VM stopped with error: \(error.localizedDescription)")
        finalizeShutdown(exitCode: 1)
    }

    func guestDidStop(_: VZVirtualMachine) {
        DaemonLogger.vm.info("VM guest has stopped.")
        finalizeShutdown(exitCode: 0)
    }

    // MARK: - Disk Image Management

    private func ensureDiskImage() throws {
        let diskURL = config.diskImageURL
        let fm = FileManager.default

        if fm.fileExists(atPath: diskURL.path) {
            return
        }

        let diskSizeBytes = try VMConfig.parseDiskSize(config.diskSize)

        // The image is sparse (truncate doesn't allocate), but it grows as the
        // guest writes. Warn early if the host volume can't plausibly hold it, so
        // users hit a clear message now rather than a cryptic ENOSPC mid-build.
        if let free = Self.availableDiskSpace(at: config.stateDirectory), free < diskSizeBytes {
            DaemonLogger.vm.warning(
                "Requested disk size \(config.diskSize) exceeds free space on the host volume "
                    + "(\(free / (1024 * 1024)) MB free). The image is sparse, but builds may fail with ENOSPC as it grows."
            )
        }

        // Create the image private to the user (0o600): it can contain build
        // artifacts and secrets pulled into the guest store.
        guard fm.createFile(atPath: diskURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw VMManagerError.diskImageCreationFailed(
                "Could not create file at \(diskURL.path)"
            )
        }

        do {
            let handle = try FileHandle(forWritingTo: diskURL)
            try handle.truncate(atOffset: diskSizeBytes)
            try handle.close()
        } catch {
            try? fm.removeItem(at: diskURL)
            throw VMManagerError.diskImageCreationFailed(error.localizedDescription)
        }
    }

    /// Free space (bytes) available on the volume backing `url`, or nil if unknown.
    static func availableDiskSpace(at url: URL) -> UInt64? {
        let probe = FileManager.default.fileExists(atPath: url.path)
            ? url
            : url.deletingLastPathComponent()
        guard let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage
        else {
            return nil
        }
        return capacity >= 0 ? UInt64(capacity) : nil
    }

    // MARK: - PID File Management

    func withPIDFile<T>(_ operation: () async throws -> T) async throws -> T {
        try writePIDFile()

        do {
            return try await operation()
        } catch {
            removePIDFile()
            virtualMachine = nil
            throw error
        }
    }

    private func writePIDFile() throws {
        let record = VMProcessRecord(
            pid: ProcessInfo.processInfo.processIdentifier,
            executablePath: Self.currentExecutablePath(),
            stateDirectory: config.stateDirectory.path,
            startedAt: Date()
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)
            try data.write(to: config.pidFileURL, options: .atomic)
        } catch {
            throw VMManagerError.pidFileWriteFailed(error.localizedDescription)
        }
    }

    private func removePIDFile() {
        try? FileManager.default.removeItem(at: config.pidFileURL)
    }

    private func removeGuestIPFile() {
        try? FileManager.default.removeItem(at: config.guestIPFileURL)
    }

    // MARK: - Static Helpers

    static func readPIDRecord(from pidFileURL: URL) -> VMProcessRecord? {
        guard let content = try? String(contentsOf: pidFileURL, encoding: .utf8) else {
            return nil
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pid = Int32(trimmed), pid > 0 {
            return VMProcessRecord(
                pid: pid,
                executablePath: nil,
                stateDirectory: pidFileURL.deletingLastPathComponent().path,
                startedAt: Date(timeIntervalSince1970: 0)
            )
        }

        guard let data = content.data(using: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(VMProcessRecord.self, from: data), record.pid > 0 else {
            return nil
        }
        return record
    }

    static func readPID(from pidFileURL: URL) -> pid_t? {
        readPIDRecord(from: pidFileURL)?.pid
    }

    static func isProcessRunning(pid: pid_t) -> Bool {
        guard pid > 0 else {
            return false
        }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    static func currentExecutablePath() -> String? {
        if let executableURL = Bundle.main.executableURL {
            return executableURL.resolvingSymlinksInPath().path
        }
        guard let executable = ProcessInfo.processInfo.arguments.first else {
            return nil
        }
        return URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    }

    static func executablePath(for pid: pid_t) -> String? {
        guard pid > 0 else {
            return nil
        }
        let bufferSize = 4096
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(bufferSize))
        }
        guard length > 0 else {
            return nil
        }
        return String(cString: buffer).nilIfEmpty.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
    }

    static func processMatchesRecord(pid: pid_t, expectedExecutablePath: String?) -> Bool {
        guard pid > 0 else {
            return false
        }
        guard let expectedExecutablePath else {
            // Legacy PID file with no recorded executable path. Don't blindly trust
            // the bare PID (it may have been recycled by an unrelated process):
            // only match if the live process actually looks like darwin-vz-nix.
            guard let actualExecutablePath = executablePath(for: pid) else {
                return false
            }
            return actualExecutablePath.contains("darwin-vz-nix")
        }
        guard let actualExecutablePath = executablePath(for: pid) else {
            return false
        }
        return actualExecutablePath == URL(fileURLWithPath: expectedExecutablePath).resolvingSymlinksInPath().path
    }

    @discardableResult
    static func terminateProcess(
        pid: pid_t,
        pidFileURL: URL,
        force: Bool = false,
        expectedExecutablePath: String? = nil
    ) throws -> Bool {
        guard pid > 0 else {
            try? FileManager.default.removeItem(at: pidFileURL)
            throw VMManagerError.stopFailed("Invalid VM process PID \(pid). Stale PID file removed.")
        }

        guard isProcessRunning(pid: pid) else {
            try? FileManager.default.removeItem(at: pidFileURL)
            DaemonLogger.vm.info("PID \(pid) is no longer running. Stale PID file removed.")
            return true
        }

        guard processMatchesRecord(pid: pid, expectedExecutablePath: expectedExecutablePath) else {
            try? FileManager.default.removeItem(at: pidFileURL)
            throw VMManagerError.stopFailed(
                "PID \(pid) no longer belongs to the recorded darwin-vz-nix process. Stale PID file removed."
            )
        }

        let stopSignal: Int32 = force ? SIGKILL : SIGTERM
        let signalName = force ? "SIGKILL" : "SIGTERM"
        DaemonLogger.vm.info("Sending \(signalName) to VM process (PID: \(pid))...")

        guard kill(pid, stopSignal) == 0 else {
            if errno == ESRCH {
                try? FileManager.default.removeItem(at: pidFileURL)
                DaemonLogger.vm.info("PID \(pid) is no longer running. Stale PID file removed.")
                return true
            }
            let err = String(cString: strerror(errno))
            throw VMManagerError.stopFailed("Failed to send \(signalName) to PID \(pid): \(err)")
        }

        DaemonLogger.vm.info("Signal sent. Waiting for VM to stop...")

        let maxWait: UInt32 = force ? 2_000_000 : 30_000_000
        let pollInterval: UInt32 = 20000
        var waited: UInt32 = 0
        while isProcessRunning(pid: pid), waited < maxWait {
            usleep(pollInterval)
            waited += pollInterval
        }

        if !force, isProcessRunning(pid: pid) {
            guard processMatchesRecord(pid: pid, expectedExecutablePath: expectedExecutablePath) else {
                try? FileManager.default.removeItem(at: pidFileURL)
                throw VMManagerError.stopFailed(
                    "PID \(pid) changed before SIGKILL fallback. Stale PID file removed."
                )
            }

            DaemonLogger.vm.warning("Process did not stop after SIGTERM. Sending SIGKILL...")
            if kill(pid, SIGKILL) == 0 {
                var killWaited: UInt32 = 0
                while isProcessRunning(pid: pid), killWaited < 2_000_000 {
                    usleep(pollInterval)
                    killWaited += pollInterval
                }
                if !isProcessRunning(pid: pid) {
                    DaemonLogger.vm.info("VM force-stopped after SIGTERM timeout.")
                }
            }
        }

        let stopped = !isProcessRunning(pid: pid)

        if stopped {
            try? FileManager.default.removeItem(at: pidFileURL)
            DaemonLogger.vm.info("VM stopped.")
        } else {
            DaemonLogger.vm.error("Process \(pid) still running after SIGKILL.")
        }

        return stopped
    }

    // MARK: - Console Output Sanitization

    /// Strip ANSI escape sequences that request terminal responses (DSR, DA).
    /// These cause the host terminal to emit cursor-position reports like ^[[68;1R
    /// which appear as garbage when --verbose tees console output to stderr.
    static func stripTerminalRequests(_ data: Data) -> Data {
        guard var string = String(data: data, encoding: .utf8) else { return data }
        // CSI sequences: \e[ <params> <final_byte>
        // DSR requests end with 'n', Device Attributes end with 'c'
        if let regex = try? NSRegularExpression(pattern: "\u{1b}\\[[0-9;]*[nc]") {
            string = regex.stringByReplacingMatches(
                in: string, range: NSRange(string.startIndex..., in: string), withTemplate: ""
            )
        }
        return string.data(using: .utf8) ?? data
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
