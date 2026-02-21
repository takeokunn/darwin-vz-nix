import Foundation

/// Monitors VM idle state by checking for active SSH connections.
/// Triggers a shutdown callback when the VM has been idle for the configured timeout.
class IdleMonitor {
    private var lastActivityTime: Date = .init()
    private var idleCheckTimer: DispatchSourceTimer?
    private let timeoutMinutes: Int
    private let guestIPFileURL: URL
    private let queue: DispatchQueue
    private let onIdleShutdown: () -> Void

    init(
        timeoutMinutes: Int,
        guestIPFileURL: URL,
        queue: DispatchQueue,
        onIdleShutdown: @escaping () -> Void
    ) {
        self.timeoutMinutes = timeoutMinutes
        self.guestIPFileURL = guestIPFileURL
        self.queue = queue
        self.onIdleShutdown = onIdleShutdown
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            _ = self.checkActivity()
            let elapsed = Date().timeIntervalSince(self.lastActivityTime)
            if elapsed >= Double(self.timeoutMinutes) * 60.0 {
                self.onIdleShutdown()
            }
        }
        timer.resume()
        idleCheckTimer = timer
    }

    func stop() {
        idleCheckTimer?.cancel()
        idleCheckTimer = nil
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

        if output.contains("ESTABLISHED") {
            lastActivityTime = Date()
            return true
        }
        return false
    }
}
