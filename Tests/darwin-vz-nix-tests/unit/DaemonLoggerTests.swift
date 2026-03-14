@testable import DarwinVZNixLib
import Testing

@Suite("DaemonLogger", .tags(.unit))
struct DaemonLoggerTests {
    @Test("static loggers have expected categories")
    func staticLoggers() {
        // Verify static loggers are accessible (smoke test)
        _ = DaemonLogger.vm
        _ = DaemonLogger.network
        _ = DaemonLogger.idle
    }
}
