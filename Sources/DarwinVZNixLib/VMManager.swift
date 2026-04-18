import Foundation
@preconcurrency import Virtualization

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
            return "No virtual machine is currently running."
        case .vmAlreadyRunning:
            return "A virtual machine is already running."
        case let .diskImageCreationFailed(reason):
            return "Failed to create disk image: \(reason)"
        case let .pidFileWriteFailed(reason):
            return "Failed to write PID file: \(reason)"
        case let .startFailed(reason):
            return "Failed to start virtual machine: \(reason)"
        case let .stopFailed(reason):
            return "Failed to stop virtual machine: \(reason)"
        case let .configurationInvalid(reason):
            return "Invalid VM configuration: \(reason)"
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
    private var idleMonitor: IdleMonitor?

    init(config: VMConfig, verbose: Bool = false) {
        self.config = config
        idleTimeoutMinutes = config.idleTimeout
        self.verbose = verbose
        super.init()
    }

    // MARK: - VM Configuration

    func createVMConfiguration() throws -> VZVirtualMachineConfiguration {
        let vmConfig = VZVirtualMachineConfiguration()

        // Boot loader
        let bootLoader = VZLinuxBootLoader(kernelURL: config.kernelURL)
        bootLoader.initialRamdiskURL = config.initrdURL
        var cmdline = "console=hvc0 root=/dev/vda"
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

        // Network (NAT) with deterministic MAC for DHCP lease discovery
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        if let mac = VZMACAddress(string: Constants.macAddressString) {
            networkDevice.macAddress = mac
        }
        vmConfig.networkDevices = [networkDevice]

        // Entropy
        vmConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Serial console — write to console.log file and optionally tee to stderr
        FileManager.default.createFile(atPath: config.consoleLogURL.path, contents: nil)
        let consoleLogHandle = try FileHandle(forWritingTo: config.consoleLogURL)

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
        let consoleReadHandle = FileHandle(forReadingAtPath: "/dev/null")!

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

        // VirtioFS: SSH keys (for guest to read host's public key)
        let sshKeysShare = try VirtioFSManager.createSSHKeysShare(sshDirectory: config.sshDirectory)
        directoryShares.append(sshKeysShare)

        vmConfig.directorySharingDevices = directoryShares

        // Validate the configuration
        do {
            try vmConfig.validate()
        } catch {
            throw VMManagerError.configurationInvalid(error.localizedDescription)
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
                queue: queue,
                onIdleShutdown: { [weak self] in
                    guard let self = self else { return }
                    DaemonLogger.idle.warning("VM idle for \(self.idleTimeoutMinutes) minute(s). Shutting down automatically.")
                    Task {
                        do {
                            try await self.stop(force: false)
                        } catch {
                            DaemonLogger.idle.warning("Idle shutdown failed: \(error.localizedDescription)")
                        }
                        Darwin.exit(0)
                    }
                }
            )
            monitor.start()
            idleMonitor = monitor
        }
    }

    func stop(force: Bool = false) async throws {
        guard let vm = virtualMachine else {
            throw VMManagerError.vmNotRunning
        }

        idleMonitor?.stop()
        idleMonitor = nil

        if force {
            // Force stop: clean up and let the caller exit the process.
            // The VM runs in-process, so process exit terminates it immediately.
            virtualMachine = nil
            removePIDFile()
            removeGuestIPFile()
            return
        }

        // Graceful: send ACPI power button request to the guest OS.
        // VZVirtualMachine requires all operations on the VM's queue.
        nonisolated(unsafe) let vmRef = vm
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try vmRef.requestStop()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        virtualMachine = nil
        removePIDFile()
        removeGuestIPFile()
    }

    // MARK: - VZVirtualMachineDelegate

    func virtualMachine(_: VZVirtualMachine, didStopWithError error: Error) {
        DaemonLogger.vm.error("VM stopped with error: \(error.localizedDescription)")
        removePIDFile()
        removeGuestIPFile()
        exit(1)
    }

    func guestDidStop(_: VZVirtualMachine) {
        DaemonLogger.vm.info("VM guest has stopped.")
        removePIDFile()
        removeGuestIPFile()
        exit(0)
    }

    // MARK: - Disk Image Management

    private func ensureDiskImage() throws {
        let diskURL = config.diskImageURL
        let fm = FileManager.default

        if fm.fileExists(atPath: diskURL.path) {
            return
        }

        let diskSizeBytes = try VMConfig.parseDiskSize(config.diskSize)

        guard fm.createFile(atPath: diskURL.path, contents: nil) else {
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
        let pid = ProcessInfo.processInfo.processIdentifier
        let pidString = "\(pid)"
        do {
            try pidString.write(to: config.pidFileURL, atomically: true, encoding: .utf8)
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

    static func readPID(from pidFileURL: URL) -> pid_t? {
        guard let content = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        return pid
    }

    static func isProcessRunning(pid: pid_t) -> Bool {
        return kill(pid, 0) == 0
    }

    @discardableResult
    static func terminateProcess(pid: pid_t, pidFileURL: URL, force: Bool = false) throws -> Bool {
        let stopSignal: Int32 = force ? SIGKILL : SIGTERM
        let signalName = force ? "SIGKILL" : "SIGTERM"
        DaemonLogger.vm.info("Sending \(signalName) to VM process (PID: \(pid))...")

        guard kill(pid, stopSignal) == 0 else {
            let err = String(cString: strerror(errno))
            throw VMManagerError.stopFailed("Failed to send \(signalName) to PID \(pid): \(err)")
        }

        DaemonLogger.vm.info("Signal sent. Waiting for VM to stop...")

        let maxWait: UInt32 = force ? 2_000_000 : 30_000_000
        var waited: UInt32 = 0
        while isProcessRunning(pid: pid), waited < maxWait {
            usleep(100_000)
            waited += 100_000
        }

        if !force, isProcessRunning(pid: pid) {
            DaemonLogger.vm.warning("Process did not stop after SIGTERM. Sending SIGKILL...")
            if kill(pid, SIGKILL) == 0 {
                var killWaited: UInt32 = 0
                while isProcessRunning(pid: pid), killWaited < 2_000_000 {
                    usleep(100_000)
                    killWaited += 100_000
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
