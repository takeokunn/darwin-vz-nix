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
        case let .invalidCoreCount(count):
            return "Invalid CPU core count: \(count). Must be at least 1."
        case let .insufficientMemory(mb):
            return "Insufficient memory: \(mb) MB. Must be at least 512 MB."
        case let .kernelNotFound(url):
            return "Kernel image not found at: \(url.path)"
        case let .initrdNotFound(url):
            return "Initrd image not found at: \(url.path)"
        case let .invalidDiskSize(size):
            return "Invalid disk size format: '\(size)'. Use format like '100G', '512M', or bytes."
        case let .stateDirectoryCreationFailed(path):
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

    static func guestIPFileURL(for stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("guest-ip")
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
        idleTimeout: Int = 0
    ) {
        self.cores = cores
        self.memory = memory
        self.diskSize = diskSize
        self.kernelURL = kernelURL
        self.initrdURL = initrdURL
        self.systemURL = systemURL?.resolvingSymlinksInPath()
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
        VMConfig.sshDirectory(for: stateDirectory)
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
                    attributes: [.posixPermissions: 0o755]
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
