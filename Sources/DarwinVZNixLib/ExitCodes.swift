import ArgumentParser
import Foundation

/// Documented process exit-code contract for `darwin-vz-nix`.
///
/// Scripts and CI can rely on these:
/// - `0`  success
/// - `1`  unexpected failure (the default for an uncaught error)
/// - `3`  operational: the VM is not running / not in the expected state
/// - `64` usage: invalid arguments or configuration (`EX_USAGE`)
public enum ExitStatus {
    public static let success: Int32 = 0
    public static let failure: Int32 = 1
    public static let operational: Int32 = 3
    public static let usage: Int32 = 64
}

/// Print a user-facing error to stderr and exit with the operational status (3).
///
/// Use this for *expected* runtime conditions such as "no running VM", which are
/// distinct from usage errors (64, e.g. bad flags) and unexpected failures (1).
/// Returning `Never` lets call sites treat it as a terminating statement.
public func exitOperational(_ message: String) throws -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    throw ExitCode(ExitStatus.operational)
}

/// Print a user-facing error to stderr and exit with the usage status (64).
///
/// Use this for *invalid configuration* — bad `--cores`/`--memory`/`--disk-size`
/// values, or missing kernel/initrd/system artifacts — so the exit code matches
/// the documented `EX_USAGE` contract. This keeps semantic validation failures
/// consistent with ArgumentParser's own parse errors (which also exit 64),
/// instead of collapsing them into the generic failure code (1).
/// Returning `Never` lets call sites treat it as a terminating statement.
public func exitUsage(_ message: String) throws -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    throw ExitCode(ExitStatus.usage)
}
