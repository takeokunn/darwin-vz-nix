import Foundation
@preconcurrency import Virtualization

enum VirtioFSError: LocalizedError {
    case rosettaNotAvailable
    case rosettaNotInstalled
    case sharedDirectoryFailed(String)

    var errorDescription: String? {
        switch self {
        case .rosettaNotAvailable:
            "Rosetta is not available on this platform (requires Apple Silicon)."
        case .rosettaNotInstalled:
            "Rosetta is not installed. Install with: softwareupdate --install-rosetta"
        case let .sharedDirectoryFailed(reason):
            "Failed to configure shared directory: \(reason)"
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
            DaemonLogger.vm.warning("Rosetta is not supported on this platform. x86_64 builds will not be available.")
            return nil

        case .notInstalled:
            if required {
                throw VirtioFSError.rosettaNotInstalled
            }
            DaemonLogger.vm.warning("Rosetta is not installed. x86_64 builds will not be available.")
            DaemonLogger.vm.info("Install with: softwareupdate --install-rosetta")
            return nil

        case .installed:
            let rosettaShare = try VZLinuxRosettaDirectoryShare()
            let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: Constants.rosettaTag)
            fsConfig.share = rosettaShare
            DaemonLogger.vm.info("Rosetta 2 enabled for x86_64 binary execution.")
            return fsConfig

        @unknown default:
            DaemonLogger.vm.warning("Unknown Rosetta availability status. Skipping.")
            return nil
        }
    }

    /// Configure a VirtioFS share exposing ONLY the host's SSH *public* key to
    /// the guest.
    ///
    /// The guest is untrusted (it runs arbitrary build jobs), so it must never
    /// see the host's private key. Rather than share the whole `ssh/` directory
    /// — which holds `id_ed25519` — we materialize a dedicated directory that
    /// contains just `id_ed25519.pub` and share that read-only. A defense-in-depth
    /// check refuses to proceed if anything resembling a private key is present.
    ///
    /// - Parameters:
    ///   - sshDirectory: The state `ssh/` directory holding the real key pair.
    ///   - shareDirectory: Destination directory to (re)build with only the public key.
    static func createSSHKeysShare(
        sshDirectory: URL,
        shareDirectory: URL
    ) throws -> VZVirtioFileSystemDeviceConfiguration {
        let fm = FileManager.default
        let publicKey = sshDirectory.appendingPathComponent("id_ed25519.pub")
        guard fm.fileExists(atPath: publicKey.path) else {
            throw VirtioFSError.sharedDirectoryFailed("SSH public key not found: \(publicKey.path)")
        }

        // CRITICAL: the source must be a real regular file, never a symlink. A
        // symlinked id_ed25519.pub pointing at the private key would otherwise be
        // resolved by the host's virtiofs when the (untrusted) guest reads it,
        // leaking the private key. `copyItem` preserves symlinks, so we reject
        // them and materialize the destination from the key's actual bytes.
        let sourceValues = try publicKey.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard sourceValues.isSymbolicLink != true, sourceValues.isRegularFile == true else {
            throw VirtioFSError.sharedDirectoryFailed(
                "SSH public key must be a regular file, not a symlink: \(publicKey.path)"
            )
        }
        let publicKeyBytes = try Data(contentsOf: publicKey)

        // Rebuild the share directory from scratch so it never accumulates extra files.
        try? fm.removeItem(at: shareDirectory)
        try fm.createDirectory(
            at: shareDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let destination = shareDirectory.appendingPathComponent("id_ed25519.pub")
        try publicKeyBytes.write(to: destination, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)

        try assertNoPrivateKey(in: shareDirectory)

        let sharedDir = VZSharedDirectory(url: shareDirectory, readOnly: true)
        let share = VZSingleDirectoryShare(directory: sharedDir)
        let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: Constants.sshKeysTag)
        fsConfig.share = share
        return fsConfig
    }

    /// Refuse to share a directory that contains anything that isn't a plain
    /// public-key file. A shareable entry must end in `.pub` AND be a regular
    /// file (never a symlink, which could resolve to a private key outside the
    /// share root when the guest reads it).
    static func assertNoPrivateKey(in directory: URL) throws {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for entry in entries {
            let url = directory.appendingPathComponent(entry)
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            let isRegularFile = values?.isRegularFile == true
            let isSymlink = values?.isSymbolicLink == true
            if !entry.hasSuffix(".pub") || isSymlink || !isRegularFile {
                throw VirtioFSError.sharedDirectoryFailed(
                    "Refusing to expose '\(entry)' to the guest: only regular public-key files may be shared (\(directory.path))."
                )
            }
        }
    }
}
