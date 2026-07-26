import Foundation

/// Monitors VM idle state by probing for active TCP connections to the guest.
/// Triggers a shutdown callback when the VM has been idle for the configured timeout.
///
/// Activity is any ESTABLISHED TCP connection to the guest — SSH interactive
/// sessions, `ssh-ng` remote/distributed Nix builds, and deploy-rs all count.
///
/// Fail-safe by design: if the probe cannot determine state (guest IP not yet
/// known, or `lsof` fails to run — which is common while the host is under the
/// heavy VirtioFS/CPU load of a large build), the sample is treated as
/// *activity*, never as idle. A VM whose state we could not observe is never
/// judged idle and killed mid-build; only an affirmatively-observed idle guest
/// advances toward auto-shutdown.
///
/// All state and the (potentially blocking) `lsof` activity probe run on a private
/// serial queue, never on the VM's queue — so polling can never stall VM operations.
final class IdleMonitor {
    private let timeoutMinutes: Int
    private let guestIPFileURL: URL
    private let onIdleShutdown: () -> Void

    /// Private serial queue for the timer, activity checks, and all mutable state.
    private let queue = DispatchQueue(label: "com.darwin-vz-nix.idle-monitor")
    private var idleCheckTimer: DispatchSourceTimer?
    private var lastActivityTime = Date()
    /// One-shot guard: ensures the shutdown callback fires at most once and that
    /// the timer is cancelled before we hand off to the shutdown coordinator.
    private var shutdownRequested = false
    private var consecutiveIdleSamples = 0

    /// Outcome of a single activity probe.
    ///
    /// `.unknown` means the probe could not observe the guest (missing/invalid
    /// guest IP, or `lsof` failed to launch). It is deliberately distinct from
    /// `.idle`: the caller treats `.unknown` as activity, so an unobservable VM
    /// is never judged idle. See `shouldCountAsActivity(_:)`.
    enum ActivityProbe: Equatable {
        case active
        case idle
        case unknown
    }

    init(
        timeoutMinutes: Int,
        guestIPFileURL: URL,
        onIdleShutdown: @escaping () -> Void
    ) {
        self.timeoutMinutes = timeoutMinutes
        self.guestIPFileURL = guestIPFileURL
        self.onIdleShutdown = onIdleShutdown
    }

    func start() {
        queue.async { [weak self] in
            self?.scheduleNextCheck(after: 30)
        }
    }

    private func scheduleNextCheck(after interval: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            guard let self, !shutdownRequested else { return }
            let probe = probeActivity()
            if Self.shouldCountAsActivity(probe) {
                lastActivityTime = Date()
                consecutiveIdleSamples = 0
            } else {
                consecutiveIdleSamples += 1
            }
            let now = Date()
            if Self.shouldShutdown(lastActivity: lastActivityTime, now: now, timeoutMinutes: timeoutMinutes) {
                shutdownRequested = true
                idleCheckTimer?.cancel()
                idleCheckTimer = nil
                onIdleShutdown()
            } else {
                let remaining = Double(timeoutMinutes) * 60 - now.timeIntervalSince(lastActivityTime)
                scheduleNextCheck(after: Self.nextPollInterval(
                    probe: probe,
                    consecutiveIdleSamples: consecutiveIdleSamples,
                    remainingIdleTime: remaining
                ))
            }
        }
        idleCheckTimer?.cancel()
        idleCheckTimer = timer
        timer.resume()
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            shutdownRequested = true
            idleCheckTimer?.cancel()
            idleCheckTimer = nil
        }
    }

    /// Pure idle decision, separated from timers and I/O for unit testing.
    static func shouldShutdown(lastActivity: Date, now: Date, timeoutMinutes: Int) -> Bool {
        guard timeoutMinutes > 0 else { return false }
        return now.timeIntervalSince(lastActivity) >= Double(timeoutMinutes) * 60.0
    }

    /// Maps a probe outcome to whether the idle timer should reset. Fail-safe:
    /// `.active` and `.unknown` both count as activity; only an affirmatively
    /// observed `.idle` guest is allowed to advance toward auto-shutdown.
    /// Pure, for unit testing.
    static func shouldCountAsActivity(_ probe: ActivityProbe) -> Bool {
        switch probe {
        case .active, .unknown:
            true
        case .idle:
            false
        }
    }

    /// Classifies `lsof` output. Pure, for unit testing.
    /// `lsof` is invoked with `-P` (numeric ports) so `ESTABLISHED` is emitted
    /// verbatim for live TCP connections; UDP has no such state, so DHCP/ARP
    /// noise on the shared NAT segment never matches.
    static func classify(lsofOutput: String) -> ActivityProbe {
        lsofOutput.contains("ESTABLISHED") ? .active : .idle
    }

    static func classify(terminationStatus: Int32, timedOut: Bool) -> ActivityProbe {
        guard !timedOut else { return .unknown }
        switch terminationStatus {
        case 0: return .active
        case 1: return .idle
        default: return .unknown
        }
    }

    static func nextPollInterval(
        probe: ActivityProbe,
        consecutiveIdleSamples: Int,
        remainingIdleTime: TimeInterval
    ) -> TimeInterval {
        let adaptiveInterval: TimeInterval = probe == .idle && consecutiveIdleSamples >= 1 ? 60 : 30
        return max(1, min(adaptiveInterval, remainingIdleTime))
    }

    /// Probes for any ESTABLISHED TCP connection to the guest. Returns
    /// `.unknown` on any inability to observe (invalid IP, `lsof` launch
    /// failure) so the caller can fail safe.
    private func probeActivity() -> ActivityProbe {
        guard let guestIP = try? String(
            contentsOf: guestIPFileURL,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines),
            // Defense in depth: only a well-formed dotted-quad may reach the
            // lsof argument list. The file is written with a validated IP, but
            // this probe must not trust file contents it did not produce.
            NetworkManager.isValidIPv4(guestIP)
        else {
            // Guest IP not yet known / unreadable: unobservable, not idle.
            return .unknown
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        // Let lsof filter TCP state itself. With `-t`, status 0 means at least
        // one matching PID and status 1 means no established connection.
        process.arguments = ["-n", "-P", "-t", "-iTCP@\(guestIP)", "-sTCP:ESTABLISHED"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            // Probe could not run (e.g. fd/resource pressure while the host is
            // saturated by a large build): unobservable, not idle.
            return .unknown
        }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            usleep(20000)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.25)
            while process.isRunning, Date() < terminationDeadline {
                usleep(20000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            return Self.classify(terminationStatus: -1, timedOut: true)
        }
        return Self.classify(terminationStatus: process.terminationStatus, timedOut: false)
    }
}
