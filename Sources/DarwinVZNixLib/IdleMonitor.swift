import Foundation

/// Monitors VM idle state by checking for active SSH connections.
/// Triggers a shutdown callback when the VM has been idle for the configured timeout.
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
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self, !shutdownRequested else { return }
            if checkActivity() {
                lastActivityTime = Date()
            }
            if Self.shouldShutdown(lastActivity: lastActivityTime, now: Date(), timeoutMinutes: timeoutMinutes) {
                shutdownRequested = true
                idleCheckTimer?.cancel()
                idleCheckTimer = nil
                onIdleShutdown()
            }
        }
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

    private func checkActivity() -> Bool {
        guard let guestIP = try? String(
            contentsOf: guestIPFileURL,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines),
            !guestIP.isEmpty
        else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        process.arguments = ["-i", "@\(guestIP):22", "-n", "-P"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        return output.contains("ESTABLISHED")
    }
}
