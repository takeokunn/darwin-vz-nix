import ArgumentParser
@testable import DarwinVZNixLib
import Testing

struct DoctorCommandTests {
    @Test
    func parsingNoArgs() throws {
        _ = try Doctor.parse([])
    }

    @Test
    func testAbstract() {
        #expect(!Doctor.configuration.abstract.isEmpty)
        let lowered = Doctor.configuration.abstract.lowercased()
        // The abstract should hint at diagnostic purpose
        let mentionsDiagnostic = lowered.contains("diagnose")
            || lowered.contains("diagnostic")
            || lowered.contains("doctor")
        #expect(mentionsDiagnostic)
    }

    @Test
    func rejectsUnknownFlags() {
        #expect(throws: Error.self) {
            _ = try Doctor.parse(["--nonexistent-flag"])
        }
    }

    @Test
    func runProcessDrainsLargeStdout() {
        let result = Doctor.runProcess(
            "/usr/bin/perl",
            ["-e", "print \"x\" x 200000"],
            useSudo: false,
            timeout: 5
        )

        #expect(result.exit == 0)
        #expect(result.stdout.count == 200_000)
        #expect(result.stderr.isEmpty)
    }

    @Test
    func runProcessDrainsLargeStdoutAndStderr() {
        let result = Doctor.runProcess(
            "/usr/bin/perl",
            ["-e", "print STDOUT \"x\" x 200000; print STDERR \"y\" x 200000"],
            useSudo: false,
            timeout: 5
        )

        #expect(result.exit == 0)
        #expect(result.stdout.count == 200_000)
        #expect(result.stderr.count == 200_000)
    }

    @Test
    func runProcessTimeout() {
        let result = Doctor.runProcess(
            "/bin/sleep",
            ["5"],
            useSudo: false,
            timeout: 0.1
        )

        #expect(result.exit == -2)
    }
}
