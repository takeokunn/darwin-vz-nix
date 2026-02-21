import Foundation
@preconcurrency import Virtualization

enum VirtioFSError: LocalizedError {
    case rosettaNotAvailable
    case rosettaNotInstalled
    case sharedDirectoryFailed(String)

    var errorDescription: String? {
        switch self {
        case .rosettaNotAvailable:
            return "Rosetta is not available on this platform (requires Apple Silicon)."
        case .rosettaNotInstalled:
            return "Rosetta is not installed. Install with: softwareupdate --install-rosetta"
        case let .sharedDirectoryFailed(reason):
            return "Failed to configure shared directory: \(reason)"
        }
    }
}

enum VirtioFSManager {
    /// Configure VirtioFS share for host's /nix/store (read-only)
    static func createNixStoreShare() throws -> VZVirtioFileSystemDeviceConfiguration {
        let nixStorePath = URL(fileURLWithPath: "/nix/store")
        guard FileManager.default.fileExists(atPath: nixStorePath.path) else {
            throw VirtioFSError.sharedDirectoryFailed("/nix/store does not exist on host")
        }

        let sharedDir = VZSharedDirectory(url: nixStorePath, readOnly: true)
        let share = VZSingleDirectoryShare(directory: sharedDir)
        let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: Constants.nixStoreTag)
        fsConfig.share = share
        return fsConfig
    }

    /// Configure Rosetta directory share (if available)
    /// Returns nil if Rosetta is not available (graceful degradation)
    static func createRosettaShare(required: Bool = false) throws -> VZVirtioFileSystemDeviceConfiguration? {
        // Check availability
        let availability = VZLinuxRosettaDirectoryShare.availability

        switch availability {
        case .notSupported:
            if required {
                throw VirtioFSError.rosettaNotAvailable
            }
            fputs("Warning: Rosetta is not supported on this platform. x86_64 builds will not be available.\n", stderr)
            return nil

        case .notInstalled:
            if required {
                throw VirtioFSError.rosettaNotInstalled
            }
            fputs("Warning: Rosetta is not installed. x86_64 builds will not be available.\n", stderr)
            fputs("Install with: softwareupdate --install-rosetta\n", stderr)
            return nil

        case .installed:
            let rosettaShare = try VZLinuxRosettaDirectoryShare()
            let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: Constants.rosettaTag)
            fsConfig.share = rosettaShare
            fputs("Rosetta 2 enabled for x86_64 binary execution.\n", stderr)
            return fsConfig

        @unknown default:
            fputs("Warning: Unknown Rosetta availability status. Skipping.\n", stderr)
            return nil
        }
    }

    /// Configure VirtioFS share for SSH keys (so guest can read host's public key)
    static func createSSHKeysShare(sshDirectory: URL) throws -> VZVirtioFileSystemDeviceConfiguration {
        guard FileManager.default.fileExists(atPath: sshDirectory.path) else {
            throw VirtioFSError.sharedDirectoryFailed("SSH directory does not exist: \(sshDirectory.path)")
        }

        let sharedDir = VZSharedDirectory(url: sshDirectory, readOnly: true)
        let share = VZSingleDirectoryShare(directory: sharedDir)
        let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: Constants.sshKeysTag)
        fsConfig.share = share
        return fsConfig
    }
}
