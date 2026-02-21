import ArgumentParser
@testable import darwin_vz_nix
import Testing

@Suite("StartCommand", .tags(.unit))
struct StartCommandTests {
    @Test("default argument values are correct when only required options provided")
    func defaultValues() throws {
        let cmd = try DarwinVZNix.Start.parse(["--kernel", "/tmp/k", "--initrd", "/tmp/i"])
        #expect(cmd.cores == 4)
        #expect(cmd.memory == 8192)
        #expect(cmd.diskSize == "100G")
        #expect(cmd.rosetta == true)
        #expect(cmd.shareNixStore == true)
        #expect(cmd.idleTimeout == 0)
        #expect(cmd.verbose == false)
    }

    @Test("configuration abstract is non-empty")
    func abstractIsNonEmpty() {
        #expect(!DarwinVZNix.Start.configuration.abstract.isEmpty)
    }
}
