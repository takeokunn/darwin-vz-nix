@testable import darwin_vz_nix
import Foundation
import Testing

@Suite("IdleMonitor", .tags(.unit))
struct IdleMonitorTests {
    @Test("init creates a monitor that can be stopped without crash")
    func initCreatesValidMonitor() {
        let url = URL(fileURLWithPath: "/tmp/guest-ip-test")
        let queue = DispatchQueue(label: "test.idle-monitor")
        let monitor = IdleMonitor(
            timeoutMinutes: 5,
            guestIPFileURL: url,
            queue: queue,
            onIdleShutdown: {}
        )
        monitor.stop()
    }

    @Test("stop is idempotent — multiple calls do not crash")
    func stopIsIdempotent() {
        let url = URL(fileURLWithPath: "/tmp/guest-ip-test")
        let queue = DispatchQueue(label: "test.idle-monitor")
        let monitor = IdleMonitor(
            timeoutMinutes: 10,
            guestIPFileURL: url,
            queue: queue,
            onIdleShutdown: {}
        )
        monitor.stop()
        monitor.stop()
        monitor.stop()
    }

    @Test("start then stop lifecycle completes without crash")
    func startThenStopLifecycle() {
        let url = URL(fileURLWithPath: "/tmp/guest-ip-test")
        let queue = DispatchQueue(label: "test.idle-monitor")
        let monitor = IdleMonitor(
            timeoutMinutes: 5,
            guestIPFileURL: url,
            queue: queue,
            onIdleShutdown: {}
        )
        monitor.start()
        monitor.stop()
    }
}
