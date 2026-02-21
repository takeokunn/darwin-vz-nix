import ArgumentParser
@testable import darwin_vz_nix
import Testing

@Suite("StopCommand", .tags(.unit))
struct StopCommandTests {
    @Test("default parsing sets force to false")
    func defaultForceIsFalse() throws {
        let cmd = try DarwinVZNix.Stop.parse([])
        #expect(cmd.force == false)
    }

    @Test("parsing with --force sets force to true")
    func forceFlag() throws {
        let cmd = try DarwinVZNix.Stop.parse(["--force"])
        #expect(cmd.force == true)
    }

    @Test("configuration abstract is non-empty")
    func abstractIsNonEmpty() {
        #expect(!DarwinVZNix.Stop.configuration.abstract.isEmpty)
    }
}
