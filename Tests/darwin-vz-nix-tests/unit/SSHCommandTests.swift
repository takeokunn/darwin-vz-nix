import ArgumentParser
@testable import DarwinVZNixLib
import Testing

@Suite("SSHCommand", .tags(.unit))
struct SSHCommandTests {
    @Test("default parsing sets extraArgs to empty array")
    func defaultExtraArgsEmpty() throws {
        let cmd = try SSH.parse([])
        #expect(cmd.extraArgs == [])
    }

    @Test("passthrough arguments after -- are captured in extraArgs")
    func passthroughArgs() throws {
        let cmd = try SSH.parse(["--", "-v"])
        #expect(cmd.extraArgs == ["-v"])
    }

    @Test("configuration abstract is non-empty")
    func abstractIsNonEmpty() {
        #expect(!SSH.configuration.abstract.isEmpty)
    }
}
