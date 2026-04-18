import ArgumentParser
@testable import DarwinVZNixLib
import Testing

@Suite("DoctorCommand", .tags(.unit))
struct DoctorCommandTests {
    @Test("default parsing with no arguments succeeds")
    func parsingNoArgs() throws {
        _ = try Doctor.parse([])
    }

    @Test("configuration abstract is non-empty and mentions diagnosis")
    func abstract() {
        #expect(!Doctor.configuration.abstract.isEmpty)
        let lowered = Doctor.configuration.abstract.lowercased()
        // The abstract should hint at diagnostic purpose
        let mentionsDiagnostic = lowered.contains("diagnose")
            || lowered.contains("diagnostic")
            || lowered.contains("doctor")
        #expect(mentionsDiagnostic)
    }

    @Test("Doctor rejects unknown flags")
    func rejectsUnknownFlags() {
        #expect(throws: Error.self) {
            _ = try Doctor.parse(["--nonexistent-flag"])
        }
    }
}
