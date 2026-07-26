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

    // MARK: - classify (pure lsof-output parsing)

    @Test
    func classifyDetectsEstablishedConnection() {
        let output = """
        COMMAND   PID  USER   FD   TYPE  DEVICE SIZE/OFF NODE NAME
        ssh     12345 take    3u   IPv4 0x1234      0t0  TCP 192.168.64.1:52344->192.168.64.5:22 (ESTABLISHED)
        """
        #expect(IdleMonitor.classify(lsofOutput: output) == .active)
    }

    @Test
    func classifyTreatsNoEstablishedAsIdle() {
        // Header only / a lone LISTEN or CLOSE_WAIT line — no live connection.
        let output = """
        COMMAND   PID  USER   FD   TYPE  DEVICE SIZE/OFF NODE NAME
        sshd    999 root     4u   IPv4 0x9999      0t0  TCP 192.168.64.5:22 (LISTEN)
        """
        #expect(IdleMonitor.classify(lsofOutput: output) == .idle)
    }

    @Test
    func classifyEmptyOutputIsIdle() {
        #expect(IdleMonitor.classify(lsofOutput: "") == .idle)
    }

    // MARK: - shouldCountAsActivity (fail-safe mapping)

    @Test
    func activeProbeCountsAsActivity() {
        #expect(IdleMonitor.shouldCountAsActivity(.active))
    }

    @Test
    func idleProbeDoesNotCountAsActivity() {
        #expect(!IdleMonitor.shouldCountAsActivity(.idle))
    }

    @Test
    func unknownProbeFailsSafeAsActivity() {
        // A probe that could not observe the guest (invalid IP, lsof failed to
        // run under load) must never let the VM be judged idle mid-build.
        #expect(IdleMonitor.shouldCountAsActivity(.unknown))
    }

    @Test
    func lsofExitStatusClassificationIsFailSafe() {
        #expect(IdleMonitor.classify(terminationStatus: 0, timedOut: false) == .active)
        #expect(IdleMonitor.classify(terminationStatus: 1, timedOut: false) == .idle)
        #expect(IdleMonitor.classify(terminationStatus: 2, timedOut: false) == .unknown)
        #expect(IdleMonitor.classify(terminationStatus: 0, timedOut: true) == .unknown)
    }

    @Test
    func adaptivePollingReducesIdleProbesWithoutOvershootingTimeout() {
        #expect(IdleMonitor.nextPollInterval(
            probe: .idle, consecutiveIdleSamples: 2, remainingIdleTime: 300
        ) == 60)
        #expect(IdleMonitor.nextPollInterval(
            probe: .active, consecutiveIdleSamples: 0, remainingIdleTime: 300
        ) == 30)
        #expect(IdleMonitor.nextPollInterval(
            probe: .idle, consecutiveIdleSamples: 3, remainingIdleTime: 7
        ) == 7)
    }
}
