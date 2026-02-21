import ArgumentParser
@testable import darwin_vz_nix
import Testing

@Suite("DarwinVZNix", .tags(.unit))
struct DarwinVZNixTests {
    @Test("commandName is darwin-vz-nix")
    func commandName() {
        #expect(DarwinVZNix.configuration.commandName == "darwin-vz-nix")
    }

    @Test("abstract is non-empty")
    func abstractIsNonEmpty() {
        #expect(!DarwinVZNix.configuration.abstract.isEmpty)
    }

    @Test("subcommands count is 4")
    func subcommandsCount() {
        #expect(DarwinVZNix.configuration.subcommands.count == 4)
    }
}
