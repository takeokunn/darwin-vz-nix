import Foundation

enum VMConfigError: LocalizedError {
    case invalidCoreCount(Int)
    case insufficientMemory(UInt64)
    case kernelNotFound(URL)
    case initrdNotFound(URL)
    case invalidDiskSize(String)
    case stateDirectoryCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCoreCount(let count):
            return "Invalid CPU core count: \(count). Must be at least 1."
        case .insufficientMemory(let mb):
            return "Insufficient memory: \(mb) MB. Must be at least 512 MB."
        case .kernelNotFound(let url):
            return "Kernel image not found at: \(url.path)"
        case .initrdNotFound(let url):
            return "Initrd image not found at: \(url.path)"
        case .invalidDiskSize(let size):
            return "Invalid disk size format: '\(size)'. Use format like '100G', '512M', or bytes."
        case .stateDirectoryCreationFailed(let path):
            return "Failed to create state directory at: \(path)"
        }
    }
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

    static let defaultStateDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("darwin-vz-nix", isDirectory: true)
    }()

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
        idleTimeout: Int = 0
    ) {
        self.cores = cores
        self.memory = memory
        self.diskSize = diskSize
        self.kernelURL = kernelURL
        self.initrdURL = initrdURL
        self.systemURL = systemURL
        self.stateDirectory = stateDirectory ?? VMConfig.defaultStateDirectory
        self.rosetta = rosetta
        self.shareNixStore = shareNixStore
        self.idleTimeout = idleTimeout
    }

    // MARK: - Computed Paths

    var diskImageURL: URL {
        stateDirectory.appendingPathComponent("disk.img")
    }

    var sshDirectory: URL {
        stateDirectory.appendingPathComponent("ssh", isDirectory: true)
    }

    var sshKeyURL: URL {
        stateDirectory
            .appendingPathComponent("ssh", isDirectory: true)
            .appendingPathComponent("id_ed25519")
    }

    var pidFileURL: URL {
        stateDirectory.appendingPathComponent("vm.pid")
    }

    var consoleLogURL: URL {
        stateDirectory.appendingPathComponent("console.log")
    }

    var guestIPFileURL: URL {
        stateDirectory.appendingPathComponent("guest-ip")
    }

    // Deterministic locally-administered MAC address for the VM.
    // "02" = locally administered + unicast; "da:72:56" = mnemonic for "darVZ".
    static let macAddressString = "02:da:72:56:00:01"

    // MARK: - Validation

    func validate() throws {
        if cores < 1 {
            throw VMConfigError.invalidCoreCount(cores)
        }

        if memory < 512 {
            throw VMConfigError.insufficientMemory(memory)
        }

        if !FileManager.default.fileExists(atPath: kernelURL.path) {
            throw VMConfigError.kernelNotFound(kernelURL)
        }

        if !FileManager.default.fileExists(atPath: initrdURL.path) {
            throw VMConfigError.initrdNotFound(initrdURL)
        }

        _ = try VMConfig.parseDiskSize(diskSize)
    }

    func ensureStateDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: stateDirectory.path) {
            do {
                try fm.createDirectory(
                    at: stateDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw VMConfigError.stateDirectoryCreationFailed(
                    "\(stateDirectory.path): \(error.localizedDescription)"
                )
            }
        }
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
                return value * multiplier
            }
        }

        guard let bytes = UInt64(trimmed), bytes > 0 else {
            throw VMConfigError.invalidDiskSize(size)
        }
        return bytes
    }
}
