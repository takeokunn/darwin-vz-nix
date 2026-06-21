@testable import DarwinVZNixLib
import Foundation
import Testing

struct ConstantsTests {
    @Test
    func nixStoreTagValue() {
        #expect(Constants.nixStoreTag == "nix-store")
    }

    @Test
    func rosettaTagValue() {
        #expect(Constants.rosettaTag == "rosetta")
    }

    @Test
    func sshKeysTagValue() {
        #expect(Constants.sshKeysTag == "ssh-keys")
    }

    @Test
    func guestHostnameValue() {
        #expect(Constants.guestHostname == "darwin-vz-guest")
    }

    @Test
    func macAddressFormat() throws {
        let pattern = #"^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(Constants.macAddressString.startIndex..., in: Constants.macAddressString)
        let match = regex.firstMatch(in: Constants.macAddressString, range: range)
        #expect(match != nil, "MAC address '\(Constants.macAddressString)' does not match expected format")
    }
}
