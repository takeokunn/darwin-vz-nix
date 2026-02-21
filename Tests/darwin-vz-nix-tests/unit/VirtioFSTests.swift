@testable import DarwinVZNixLib
import Testing

@Suite("VirtioFS", .tags(.unit))
struct VirtioFSTests {
    @Test("rosettaNotAvailable error description is non-nil and contains expected keywords")
    func rosettaNotAvailableDescription() throws {
        let error = VirtioFSError.rosettaNotAvailable
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(try #require(desc?.contains("Rosetta")))
        #expect(try #require(desc?.contains("not available")))
    }

    @Test("rosettaNotInstalled error description is non-nil and contains expected keywords")
    func rosettaNotInstalledDescription() throws {
        let error = VirtioFSError.rosettaNotInstalled
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(try #require(desc?.contains("not installed")))
    }

    @Test("sharedDirectoryFailed error description is non-nil and contains the reason")
    func sharedDirectoryFailedDescription() throws {
        let reason = "/nix/store does not exist"
        let error = VirtioFSError.sharedDirectoryFailed(reason)
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(try #require(desc?.contains(reason)))
        #expect(try #require(desc?.contains("shared directory")))
    }
}
