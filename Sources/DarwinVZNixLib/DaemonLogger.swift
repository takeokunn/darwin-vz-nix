import Foundation
import OSLog

/// Dual-output logger: writes to both unified log (Console.app / `log stream`)
/// and stderr (captured by launchd to daemon.log).
struct DaemonLogger {
    static let vm = DaemonLogger(category: "vm")
    static let network = DaemonLogger(category: "network")
    static let idle = DaemonLogger(category: "idle")

    private let oslog: Logger
    private let category: String

    private init(category: String) {
        self.category = category
        oslog = Logger(subsystem: "org.nixos.darwin-vz-nix", category: category)
    }

    func info(_ message: String) {
        oslog.info("\(message, privacy: .public)")
        fputs("[INFO] \(message)\n", stderr)
    }

    func warning(_ message: String) {
        oslog.warning("\(message, privacy: .public)")
        fputs("[WARN] \(message)\n", stderr)
    }

    func error(_ message: String) {
        oslog.error("\(message, privacy: .public)")
        fputs("[ERROR] \(message)\n", stderr)
    }
}
