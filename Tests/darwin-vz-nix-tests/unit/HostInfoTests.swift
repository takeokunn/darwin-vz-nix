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

    @Test("parseBridgeInterfaces handles whitespace-only input")
    func parseBridgeInterfacesWhitespaceOnly() {
        #expect(HostInfo.parseBridgeInterfaces("   \n   ").isEmpty)
    }

    @Test("parseBridgeInterfaces does not match capitalized 'Bridge'")
    func parseBridgeInterfacesCaseSensitive() {
        let input = "lo0 Bridge100 bridge101"
        #expect(HostInfo.parseBridgeInterfaces(input) == ["bridge101"])
    }

    @Test("parseBridgeInterfaces preserves order of multiple bridges")
    func parseBridgeInterfacesOrder() {
        let input = "bridge200 lo0 bridge100 en0 bridge150"
        #expect(HostInfo.parseBridgeInterfaces(input) == ["bridge200", "bridge100", "bridge150"])
    }

    @Test("parseBridgeInterfaces matches 'bridge' prefix even when interface has extra suffix")
    func parseBridgeInterfacesPrefix() {
        let input = "bridge0 bridgexyz bridge-999"
        #expect(HostInfo.parseBridgeInterfaces(input) == ["bridge0", "bridgexyz", "bridge-999"])
    }

    @Test("parseBridgeInterfaces returns single bridge with leading whitespace")
    func parseBridgeInterfacesLeadingWhitespace() {
        let input = "   bridge100   "
        #expect(HostInfo.parseBridgeInterfaces(input) == ["bridge100"])
    }

    // MARK: - isMacOS14_4OrLater

    @Test("isMacOS14_4OrLater returns consistent result across calls")
    func isMacOS144Consistent() {
        let a = HostInfo.isMacOS14_4OrLater
        let b = HostInfo.isMacOS14_4OrLater
        #expect(a == b)
    }
}
