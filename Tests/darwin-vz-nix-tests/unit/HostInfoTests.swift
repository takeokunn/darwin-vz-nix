@testable import DarwinVZNixLib
import Testing

struct HostInfoTests {
    @Test
    func parseBridgeInterfacesFiltersBridges() {
        let input = "lo0 gif0 stf0 en0 en1 bridge100 utun0 bridge101"
        let bridges = HostInfo.parseBridgeInterfaces(input)
        #expect(bridges == ["bridge100", "bridge101"])
    }

    @Test
    func parseBridgeInterfacesNone() {
        let input = "lo0 en0 en1"
        #expect(HostInfo.parseBridgeInterfaces(input).isEmpty)
    }

    @Test
    func parseBridgeInterfacesTrailingNewline() {
        let input = "lo0 en0 bridge100\n"
        #expect(HostInfo.parseBridgeInterfaces(input) == ["bridge100"])
    }

    @Test
    func parseBridgeInterfacesEmpty() {
        #expect(HostInfo.parseBridgeInterfaces("").isEmpty)
    }

    @Test
    func parseBridgeInterfacesWhitespaceOnly() {
        #expect(HostInfo.parseBridgeInterfaces("   \n   ").isEmpty)
    }

    @Test
    func parseBridgeInterfacesCaseSensitive() {
        let input = "lo0 Bridge100 bridge101"
        #expect(HostInfo.parseBridgeInterfaces(input) == ["bridge101"])
    }

    @Test
    func parseBridgeInterfacesOrder() {
        let input = "bridge200 lo0 bridge100 en0 bridge150"
        #expect(HostInfo.parseBridgeInterfaces(input) == ["bridge200", "bridge100", "bridge150"])
    }

    @Test
    func parseBridgeInterfacesPrefix() {
        let input = "bridge0 bridgexyz bridge-999"
        #expect(HostInfo.parseBridgeInterfaces(input) == ["bridge0", "bridgexyz", "bridge-999"])
    }

    @Test
    func parseBridgeInterfacesLeadingWhitespace() {
        let input = "   bridge100   "
        #expect(HostInfo.parseBridgeInterfaces(input) == ["bridge100"])
    }

    // MARK: - isMacOS14_4OrLater

    @Test
    func isMacOS144Consistent() {
        let a = HostInfo.isMacOS14_4OrLater
        let b = HostInfo.isMacOS14_4OrLater
        #expect(a == b)
    }
}
