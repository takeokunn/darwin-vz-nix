import Foundation

enum NetworkError: LocalizedError {
    case sshKeyGenerationFailed(Int32)
    case sshConnectionFailed(Int32)
    case sshKeyNotFound(String)

    var errorDescription: String? {
        switch self {
        case .sshKeyGenerationFailed(let status):
            return "SSH key generation failed with exit code: \(status)"
        case .sshConnectionFailed(let status):
            return "SSH connection failed with exit code: \(status)"
        case .sshKeyNotFound(let path):
            return "SSH key not found at: \(path)"
        }
    }
}

struct NetworkManager {
    let stateDirectory: URL

    var sshKeyPath: URL {
        stateDirectory
            .appendingPathComponent("ssh", isDirectory: true)
            .appendingPathComponent("id_ed25519")
    }

    var sshPublicKeyPath: URL {
        stateDirectory
            .appendingPathComponent("ssh", isDirectory: true)
            .appendingPathComponent("id_ed25519.pub")
    }

    func ensureSSHKeys() throws {
        let sshDir = stateDirectory.appendingPathComponent("ssh", isDirectory: true)

        try FileManager.default.createDirectory(
            at: sshDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if FileManager.default.fileExists(atPath: sshKeyPath.path) {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = [
            "-q",
            "-f", sshKeyPath.path,
            "-t", "ed25519",
            "-N", "",
            "-C", "builder@darwin-vz-nix",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NetworkError.sshKeyGenerationFailed(process.terminationStatus)
        }
    }

    func connectSSH(port: UInt16 = 31122, extraArgs: [String] = []) throws {
        guard FileManager.default.fileExists(atPath: sshKeyPath.path) else {
            throw NetworkError.sshKeyNotFound(sshKeyPath.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-i", sshKeyPath.path,
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(stateDirectory.appendingPathComponent("ssh/known_hosts").path)",
            "-o", "LogLevel=ERROR",
            "-p", String(port),
            "builder@localhost",
        ] + extraArgs
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        let status = process.terminationStatus
        if status != 0 {
            throw NetworkError.sshConnectionFailed(status)
        }
    }
}
