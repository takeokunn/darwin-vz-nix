@testable import DarwinVZNixLib
import Foundation
import Testing

@Suite("Constants", .tags(.unit))
struct ConstantsTests {
    @Test("nixStoreTag has expected string value")
    func nixStoreTagValue() {
        #expect(Constants.nixStoreTag == "nix-store")
    }

    @Test("rosettaTag has expected string value")
    func rosettaTagValue() {
        #expect(Constants.rosettaTag == "rosetta")
    }

    @Test("sshKeysTag has expected string value")
    func sshKeysTagValue() {
        #expect(Constants.sshKeysTag == "ssh-keys")
    }

    @Test("guestHostname has expected value")
    func guestHostnameValue() {
        #expect(Constants.guestHostname == "darwin-vz-guest")
    }

    @Test("MAC address matches valid format")
    func macAddressFormat() throws {
        let pattern = #"^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(Constants.macAddressString.startIndex..., in: Constants.macAddressString)
        let match = regex.firstMatch(in: Constants.macAddressString, range: range)
        #expect(match != nil, "MAC address '\(Constants.macAddressString)' does not match expected format")
    }
}
