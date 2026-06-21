@testable import DarwinVZNixLib
import Testing

struct DaemonLoggerTests {
    @Test
    func staticLoggers() {
        // Verify static loggers are accessible (smoke test)
        _ = DaemonLogger.vm
        _ = DaemonLogger.network
        _ = DaemonLogger.idle
    }
}
