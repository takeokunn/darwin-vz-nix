@testable import DarwinVZNixLib
import Testing

@Suite("HostInfo", .tags(.unit))
struct HostInfoTests {
    @Test("parseBridgeInterfaces returns only bridge names")
    func parseBridgeInterfacesFiltersBridges() {
        let input = "lo0 gif0 stf0 en0 en1 bridge100 utun0 bridge101"
        let bridges = HostInfo.parseBridgeInterfaces(input)
        #expect(bridges == ["bridge100", "bridge101"])
    }

    @Test("parseBridgeInterfaces returns empty when no bridges present")
    func parseBridgeInterfacesNone() {
        let input = "lo0 en0 en1"
        #expect(HostInfo.parseBridgeInterfaces(input).isEmpty)
    }

    @Test("parseBridgeInterfaces handles trailing newline")
    func parseBridgeInterfacesTrailingNewline() {
        let input = "lo0 en0 bridge100\n"
        #expect(HostInfo.parseBridgeInterfaces(input) == ["bridge100"])
    }

    @Test("parseBridgeInterfaces handles empty input")
    func parseBridgeInterfacesEmpty() {
        #expect(HostInfo.parseBridgeInterfaces("").isEmpty)
    }
}
