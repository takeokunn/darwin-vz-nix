import ArgumentParser
@testable import DarwinVZNixLib
import Testing

@Suite("StopCommand", .tags(.unit))
struct StopCommandTests {
    @Test("default parsing sets force to false")
    func defaultForceIsFalse() throws {
        let cmd = try Stop.parse([])
        #expect(cmd.force == false)
    }

    @Test("parsing with --force sets force to true")
    func forceFlag() throws {
        let cmd = try Stop.parse(["--force"])
        #expect(cmd.force == true)
    }

    @Test("configuration abstract is non-empty")
    func abstractIsNonEmpty() {
        #expect(!Stop.configuration.abstract.isEmpty)
    }
}
