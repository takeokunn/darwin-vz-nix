import ArgumentParser
@testable import DarwinVZNixLib
import Testing

@Suite("DestroyCommand", .tags(.unit))
struct DestroyCommandTests {
    @Test("default parsing sets yes to false and stateDir to nil")
    func defaultFlags() throws {
        let cmd = try Destroy.parse([])
        #expect(cmd.yes == false)
        #expect(cmd.stateDir == nil)
    }

    @Test("--yes flag sets yes to true")
    func yesFlag() throws {
        let cmd = try Destroy.parse(["--yes"])
        #expect(cmd.yes == true)
    }

    @Test("--state-dir option stores the provided path")
    func stateDirOption() throws {
        let cmd = try Destroy.parse(["--state-dir", "/tmp/custom"])
        #expect(cmd.stateDir == "/tmp/custom")
    }

    @Test("combining --yes and --state-dir parses both")
    func combinedOptions() throws {
        let cmd = try Destroy.parse(["--yes", "--state-dir", "/custom/path"])
        #expect(cmd.yes == true)
        #expect(cmd.stateDir == "/custom/path")
    }

    @Test("configuration abstract is non-empty and mentions destruction")
    func abstract() {
        #expect(!Destroy.configuration.abstract.isEmpty)
        #expect(Destroy.configuration.abstract.lowercased().contains("destroy"))
    }
}
