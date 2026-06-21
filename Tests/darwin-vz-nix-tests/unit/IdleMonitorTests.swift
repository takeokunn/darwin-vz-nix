@testable import DarwinVZNixLib
import Foundation
import Testing

struct IdleMonitorTests {
    @Test
    func initCreatesValidMonitor() {
        let url = URL(fileURLWithPath: "/tmp/guest-ip-test")
        let monitor = IdleMonitor(
            timeoutMinutes: 5,
            guestIPFileURL: url,
            onIdleShutdown: {}
        )
        monitor.stop()
    }

    @Test
    func stopIsIdempotent() {
        let url = URL(fileURLWithPath: "/tmp/guest-ip-test")
        let monitor = IdleMonitor(
            timeoutMinutes: 10,
            guestIPFileURL: url,
            onIdleShutdown: {}
        )
        monitor.stop()
        monitor.stop()
        monitor.stop()
    }

    @Test
    func startThenStopLifecycle() {
        let url = URL(fileURLWithPath: "/tmp/guest-ip-test")
        let monitor = IdleMonitor(
            timeoutMinutes: 5,
            guestIPFileURL: url,
            onIdleShutdown: {}
        )
        monitor.start()
        monitor.stop()
    }

    // MARK: - shouldShutdown (pure decision)

    @Test
    func shouldShutdownWhenIdleBeyondTimeout() {
        let now = Date()
        let lastActivity = now.addingTimeInterval(-6 * 60) // 6 minutes ago
        #expect(IdleMonitor.shouldShutdown(lastActivity: lastActivity, now: now, timeoutMinutes: 5))
    }

    @Test
    func shouldNotShutdownWithinTimeout() {
        let now = Date()
        let lastActivity = now.addingTimeInterval(-2 * 60) // 2 minutes ago
        #expect(!IdleMonitor.shouldShutdown(lastActivity: lastActivity, now: now, timeoutMinutes: 5))
    }

    @Test
    func shouldShutdownExactlyAtTimeoutBoundary() {
        let now = Date()
        let lastActivity = now.addingTimeInterval(-5 * 60) // exactly 5 minutes ago
        #expect(IdleMonitor.shouldShutdown(lastActivity: lastActivity, now: now, timeoutMinutes: 5))
    }

    @Test
    func zeroTimeoutNeverShutsDown() {
        let now = Date()
        let lastActivity = now.addingTimeInterval(-1000 * 60)
        #expect(!IdleMonitor.shouldShutdown(lastActivity: lastActivity, now: now, timeoutMinutes: 0))
    }
}
