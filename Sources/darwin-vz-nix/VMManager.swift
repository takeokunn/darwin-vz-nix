import Foundation
import Virtualization

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
        case .diskImageCreationFailed(let reason):
            return "Failed to create disk image: \(reason)"
        case .pidFileWriteFailed(let reason):
            return "Failed to write PID file: \(reason)"
        case .startFailed(let reason):
            return "Failed to start virtual machine: \(reason)"
        case .stopFailed(let reason):
            return "Failed to stop virtual machine: \(reason)"
        case .configurationInvalid(let reason):
            return "Invalid VM configuration: \(reason)"
        }
    }
}

class VMManager: NSObject, VZVirtualMachineDelegate {
    private var virtualMachine: VZVirtualMachine?
    private let config: VMConfig
    private let queue = DispatchQueue(label: "com.darwin-vz-nix.vm")
    private var lastActivityTime: Date = Date()
    private var idleCheckTimer: DispatchSourceTimer?
    private let idleTimeoutMinutes: Int

    init(config: VMConfig) {
        self.config = config
        self.idleTimeoutMinutes = config.idleTimeout
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

        // Network (NAT)
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        vmConfig.networkDevices = [networkDevice]

        // Entropy
        vmConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Serial console — write to console.log file and optionally read from stdin
        FileManager.default.createFile(atPath: config.consoleLogURL.path, contents: nil)
        let consoleWriteHandle = try FileHandle(forWritingTo: config.consoleLogURL)

        // Use /dev/null for input when stdin is not a TTY (e.g. backgrounded process)
        let consoleReadHandle: FileHandle
        if isatty(STDIN_FILENO) != 0 {
            consoleReadHandle = FileHandle.standardInput
        } else {
            consoleReadHandle = FileHandle(forReadingAtPath: "/dev/null")!
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
        self.virtualMachine = vm

        try writePIDFile()

        // VZVirtualMachine requires all operations on the queue specified in init.
        // Swift async/await runs on the cooperative thread pool, which is NOT the VM's queue.
        // We must dispatch start() to the VM's DispatchQueue explicitly.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                vm.start { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        if idleTimeoutMinutes > 0 {
            startIdleMonitoring()
        }
    }

    func stop(force: Bool = false) async throws {
        guard let vm = virtualMachine else {
            throw VMManagerError.vmNotRunning
        }

        idleCheckTimer?.cancel()
        idleCheckTimer = nil

        if force {
            // Force stop: clean up and let the caller exit the process.
            // The VM runs in-process, so process exit terminates it immediately.
            self.virtualMachine = nil
            removePIDFile()
            return
        }

        // Graceful: send ACPI power button request to the guest OS.
        // VZVirtualMachine requires all operations on the VM's queue.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try vm.requestStop()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        self.virtualMachine = nil
        removePIDFile()
    }

    // MARK: - VZVirtualMachineDelegate

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        fputs("VM stopped with error: \(error.localizedDescription)\n", stderr)
        removePIDFile()
        exit(1)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        fputs("VM guest has stopped.\n", stderr)
        removePIDFile()
        exit(0)
    }

    // MARK: - Idle Timeout Monitoring

    private func startIdleMonitoring() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let _ = self.checkActivity()
            let elapsed = Date().timeIntervalSince(self.lastActivityTime)
            if elapsed >= Double(self.idleTimeoutMinutes) * 60.0 {
                self.shutdownDueToIdle()
            }
        }
        timer.resume()
        idleCheckTimer = timer
    }

    private func checkActivity() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        process.arguments = ["-i", ":\(Constants.defaultSSHPort)", "-n", "-P"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if output.contains("ESTABLISHED") {
            lastActivityTime = Date()
            return true
        }
        return false
    }

    private func shutdownDueToIdle() {
        fputs("Warning: VM idle for \(idleTimeoutMinutes) minute(s). Shutting down automatically.\n", stderr)
        Task {
            do {
                try await self.stop(force: false)
            } catch {
                fputs("Warning: Idle shutdown failed: \(error.localizedDescription)\n", stderr)
            }
            Darwin.exit(0)
        }
    }

    func resetActivityTimer() {
        lastActivityTime = Date()
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
}
