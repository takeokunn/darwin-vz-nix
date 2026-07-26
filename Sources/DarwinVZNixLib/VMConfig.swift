import Foundation

enum VMConfigError: LocalizedError {
    case invalidCoreCount(Int)
    case insufficientMemory(UInt64)
    case kernelNotFound(URL, hint: String?)
    case initrdNotFound(URL, hint: String?)
    case systemInitNotFound(URL)
    case invalidDiskSize(String)
    case stateDirectoryCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidCoreCount(count):
            return "Invalid CPU core count: \(count). Must be at least 1."
        case let .insufficientMemory(mb):
            return "Insufficient memory: \(mb) MB. Must be at least 512 MB."
        case let .kernelNotFound(url, hint):
            var msg = "Kernel image not found at: \(url.path)"
            if let hint { msg += "\nHint: \(hint)" }
            msg += "\n\(VMConfigError.guestArtifactGuidance)"
            return msg
        case let .initrdNotFound(url, hint):
            var msg = "Initrd image not found at: \(url.path)"
            if let hint { msg += "\nHint: \(hint)" }
            msg += "\n\(VMConfigError.guestArtifactGuidance)"
            return msg
        case let .systemInitNotFound(url):
            return "NixOS system init not found at: \(url.path)"
        case let .invalidDiskSize(size):
            return "Invalid disk size format: '\(size)'. Use format like '100G', '512M', or bytes."
        case let .stateDirectoryCreationFailed(path):
            return "Failed to create state directory at: \(path)"
        }
    }

    /// Shared first-run guidance for missing guest artifacts (kernel/initrd/system).
    static let guestArtifactGuidance = """
    The guest kernel, initrd, and system are aarch64-linux artifacts. Build or fetch them with:
      nix run .#build-guest-artifacts
    This writes ./result-kernel/Image, ./result-initrd/initrd, and ./result-system. Then:
      darwin-vz-nix start --kernel ./result-kernel/Image --initrd ./result-initrd/initrd --system ./result-system
    """
}

struct VMConfig {
    let cores: Int
    let memory: UInt64
    let diskSize: String
    let kernelURL: URL
    let initrdURL: URL
    let systemURL: URL?
    let stateDirectory: URL
    let rosetta: Bool
    let shareNixStore: Bool
    let idleTimeout: Int
    let launchdManaged: Bool

    static let defaultStateDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("darwin-vz-nix", isDirectory: true)
    }()

    static var defaultPIDFileURL: URL {
        defaultStateDirectory.appendingPathComponent("vm.pid")
    }

    // MARK: - Static Path Helpers

    static func sshKeyURL(for stateDirectory: URL) -> URL {
        stateDirectory
            .appendingPathComponent("ssh", isDirectory: true)
            .appendingPathComponent("id_ed25519")
    }

    static func sshDirectory(for stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("ssh", isDirectory: true)
    }

    /// Directory shared into the guest via VirtioFS. Contains ONLY the public
    /// key — never the private key. See `VMConfig.sshPublicShareDirectory`.
    static func sshPublicShareDirectory(for stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("ssh-pub", isDirectory: true)
    }

    static func guestIPFileURL(for stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("guest-ip")
    }

    /// Deterministic per-state-directory MAC address.
    ///
    /// Multiple VMs on the same host share one NAT segment; a fixed MAC would
    /// collide and corrupt DHCP-lease/ARP-based IP discovery (two guests, one
    /// MAC). We keep the recognizable locally-administered unicast prefix
    /// `02:da:72` ("darVZ") and derive the last three octets from a stable
    /// FNV-1a hash of the resolved state-directory path, so each state directory
    /// gets its own stable address while a given VM's MAC never changes.
    ///
    /// Note: this implies a single VM per state directory (the documented model).
    static func macAddress(for stateDirectory: URL) -> String {
        // Keep the recognizable OUI prefix (first three octets) from the base MAC
        // constant, and derive the host-specific last three octets per state dir.
        let prefix = Constants.macAddressString.split(separator: ":").prefix(3).joined(separator: ":")
        let path = stateDirectory.resolvingSymlinksInPath().path
        var hash: UInt32 = 2_166_136_261 // FNV-1a 32-bit offset basis
        for byte in path.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let octet1 = (hash >> 16) & 0xFF
        let octet2 = (hash >> 8) & 0xFF
        let octet3 = hash & 0xFF
        return String(format: "\(prefix):%02x:%02x:%02x", octet1, octet2, octet3)
    }

    init(
        cores: Int = 4,
        memory: UInt64 = 8192,
        diskSize: String = "100G",
        kernelURL: URL,
        initrdURL: URL,
        systemURL: URL? = nil,
        stateDirectory: URL? = nil,
        rosetta: Bool = true,
        shareNixStore: Bool = true,
        idleTimeout: Int = 0,
        launchdManaged: Bool = false
    ) {
        self.cores = cores
        self.memory = memory
        self.diskSize = diskSize
        self.kernelURL = kernelURL.resolvingSymlinksInPath()
        self.initrdURL = initrdURL.resolvingSymlinksInPath()
        self.systemURL = systemURL?.resolvingSymlinksInPath()
        self.stateDirectory = stateDirectory ?? VMConfig.defaultStateDirectory
        self.rosetta = rosetta
        self.shareNixStore = shareNixStore
        self.idleTimeout = idleTimeout
        self.launchdManaged = launchdManaged
    }

    // MARK: - Computed Paths

    var diskImageURL: URL {
        stateDirectory.appendingPathComponent("disk.img")
    }

    var sshDirectory: URL {
        VMConfig.sshDirectory(for: stateDirectory)
    }

    /// Public-key-only directory exposed to the (untrusted) guest over VirtioFS.
    var sshPublicShareDirectory: URL {
        VMConfig.sshPublicShareDirectory(for: stateDirectory)
    }

    /// Deterministic per-state-directory MAC for this VM's network device.
    var macAddress: String {
        VMConfig.macAddress(for: stateDirectory)
    }

    var sshKeyURL: URL {
        VMConfig.sshKeyURL(for: stateDirectory)
    }

    var pidFileURL: URL {
        stateDirectory.appendingPathComponent("vm.pid")
    }

    var consoleLogURL: URL {
        stateDirectory.appendingPathComponent("console.log")
    }

    var guestIPFileURL: URL {
        VMConfig.guestIPFileURL(for: stateDirectory)
    }

    // MARK: - Validation

    func validate() throws {
        if cores < 1 {
            throw VMConfigError.invalidCoreCount(cores)
        }

        if memory < 512 {
            throw VMConfigError.insufficientMemory(memory)
        }

        if !Self.isRegularFile(kernelURL) {
            let dir = kernelURL.deletingLastPathComponent()
            var hint: String?
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("initrd").path) {
                hint = "Found 'initrd' in the same directory, which is an initrd artifact.\n"
                    + "      You may have built guest-initrd instead of guest-kernel into this path."
            }
            throw VMConfigError.kernelNotFound(kernelURL, hint: hint)
        }

        if !Self.isRegularFile(initrdURL) {
            let dir = initrdURL.deletingLastPathComponent()
            var hint: String?
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Image").path) {
                hint = "Found 'Image' in the same directory, which is a kernel artifact.\n"
                    + "      You may have built guest-kernel instead of guest-initrd into this path."
            }
            throw VMConfigError.initrdNotFound(initrdURL, hint: hint)
        }

        if let systemURL {
            let initURL = systemURL.appendingPathComponent("init")
            guard Self.isRegularFile(initURL) else {
                throw VMConfigError.systemInitNotFound(initURL)
            }
        }

        _ = try VMConfig.parseDiskSize(diskSize)
    }

    func ensureStateDirectory() throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: stateDirectory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw VMConfigError.stateDirectoryCreationFailed(
                    "\(stateDirectory.path): exists and is not a directory"
                )
            }
        } else {
            do {
                try fm.createDirectory(
                    at: stateDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o755]
                )
            } catch {
                throw VMConfigError.stateDirectoryCreationFailed(
                    "\(stateDirectory.path): \(error.localizedDescription)"
                )
            }
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard
            let fileType = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        else {
            return false
        }
        return fileType == .typeRegular
    }

    // MARK: - Disk Size Parsing

    static func parseDiskSize(_ size: String) throws -> UInt64 {
        let trimmed = size.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw VMConfigError.invalidDiskSize(size)
        }

        let suffixes: [(String, UInt64)] = [
            ("T", 1024 * 1024 * 1024 * 1024),
            ("G", 1024 * 1024 * 1024),
            ("M", 1024 * 1024),
            ("K", 1024),
        ]

        for (suffix, multiplier) in suffixes {
            if trimmed.uppercased().hasSuffix(suffix) {
                let numberPart = String(trimmed.dropLast(1))
                guard let value = UInt64(numberPart), value > 0 else {
                    throw VMConfigError.invalidDiskSize(size)
                }
                let result = value.multipliedReportingOverflow(by: multiplier)
                guard !result.overflow, result.partialValue > 0 else {
                    throw VMConfigError.invalidDiskSize(size)
                }
                return result.partialValue
            }
        }

        guard let bytes = UInt64(trimmed), bytes > 0 else {
            throw VMConfigError.invalidDiskSize(size)
        }
        return bytes
    }
}
