@testable import DarwinVZNixLib
import Testing

@Suite("Networking", .tags(.unit))
struct NetworkingTests {
    let sampleLease = """
    {
        name=darwin-vz-guest
        ip_address=192.168.64.2
        hw_address=1,2:da:72:56:0:1
        identifier=1,2:da:72:56:0:1
        lease=0x67000001
    }
    """

    let multipleLeases = """
    {
        name=darwin-vz-guest
        ip_address=192.168.64.2
        hw_address=1,2:da:72:56:0:1
        identifier=1,2:da:72:56:0:1
        lease=0x67000001
    }
    {
        name=darwin-vz-guest
        ip_address=192.168.64.3
        hw_address=1,2:da:72:56:0:1
        identifier=1,2:da:72:56:0:1
        lease=0x67000099
    }
    """

    // MARK: - parseLeaseContent matching hostname

    @Test("parseLeaseContent returns IP for matching hostname")
    func parseLeaseContentMatchingHostname() {
        let ip = NetworkManager.parseLeaseContent(sampleLease, hostname: "darwin-vz-guest", notBefore: 0)
        #expect(ip == "192.168.64.2")
    }

    // MARK: - parseLeaseContent non-matching hostname

    @Test("parseLeaseContent returns nil for non-matching hostname")
    func parseLeaseContentNonMatchingHostname() {
        let ip = NetworkManager.parseLeaseContent(sampleLease, hostname: "wrong-host", notBefore: 0)
        #expect(ip == nil)
    }

    // MARK: - parseLeaseContent notBefore filter

    @Test("parseLeaseContent filters old lease via notBefore, returns newer lease")
    func parseLeaseContentNotBeforeFilter() {
        let ip = NetworkManager.parseLeaseContent(multipleLeases, hostname: "darwin-vz-guest", notBefore: 0x6700_0050)
        #expect(ip == "192.168.64.3")
    }

    @Test("parseLeaseContent returns nil when notBefore filters all leases")
    func parseLeaseContentNotBeforeFiltersAll() {
        let ip = NetworkManager.parseLeaseContent(sampleLease, hostname: "darwin-vz-guest", notBefore: 0xFFFF_FFFF)
        #expect(ip == nil)
    }

    // MARK: - parseLeaseContent multiple leases

    @Test("parseLeaseContent selects newest lease among multiple entries")
    func parseLeaseContentSelectsNewest() {
        let ip = NetworkManager.parseLeaseContent(multipleLeases, hostname: "darwin-vz-guest", notBefore: 0)
        #expect(ip == "192.168.64.3")
    }

    @Test("parseLeaseContent selects correct host among mixed leases")
    func parseLeaseContentMixedHosts() {
        let mixedLeases = """
        {
            name=other-vm
            ip_address=192.168.64.5
            lease=0x67000099
        }
        {
            name=darwin-vz-guest
            ip_address=192.168.64.2
            lease=0x67000001
        }
        """
        let ip = NetworkManager.parseLeaseContent(mixedLeases, hostname: "darwin-vz-guest", notBefore: 0)
        #expect(ip == "192.168.64.2")
    }

    // MARK: - parseLeaseContent empty/malformed

    @Test("parseLeaseContent returns nil for empty content")
    func parseLeaseContentEmpty() {
        let ip = NetworkManager.parseLeaseContent("", hostname: "darwin-vz-guest", notBefore: 0)
        #expect(ip == nil)
    }

    @Test("parseLeaseContent returns nil for malformed content")
    func parseLeaseContentMalformed() {
        let malformed = "this is not a lease file at all"
        let ip = NetworkManager.parseLeaseContent(malformed, hostname: "darwin-vz-guest", notBefore: 0)
        #expect(ip == nil)
    }

    // MARK: - normalizeMAC

    @Test("normalizeMAC removes leading zeros from each octet")
    func normalizeMACRemovesLeadingZeros() {
        #expect(NetworkManager.normalizeMAC("02:da:72:56:00:01") == "2:da:72:56:0:1")
    }

    @Test("normalizeMAC handles already-normalized MAC")
    func normalizeMACAlreadyNormalized() {
        #expect(NetworkManager.normalizeMAC("2:da:72:56:0:1") == "2:da:72:56:0:1")
    }

    @Test("normalizeMAC preserves zero octet as '0'")
    func normalizeMACPreservesZero() {
        #expect(NetworkManager.normalizeMAC("00:00:00:00:00:00") == "0:0:0:0:0:0")
    }

    @Test("normalizeMAC is case-insensitive")
    func normalizeMACCaseInsensitive() {
        #expect(NetworkManager.normalizeMAC("02:DA:72:56:00:01") == "2:da:72:56:0:1")
    }

    // MARK: - NetworkError.errorDescription

    @Test("sshKeyGenerationFailed error description is non-nil and contains exit code")
    func errorDescriptionSSHKeyGenerationFailed() throws {
        let error = NetworkError.sshKeyGenerationFailed(1)
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(try #require(desc?.contains("1")))
        #expect(try #require(desc?.contains("key generation")))
    }

    @Test("sshConnectionFailed error description is non-nil and contains exit code")
    func errorDescriptionSSHConnectionFailed() throws {
        let error = NetworkError.sshConnectionFailed(255)
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(try #require(desc?.contains("255")))
        #expect(try #require(desc?.contains("connection")))
    }

    @Test("sshKeyNotFound error description is non-nil and contains path")
    func errorDescriptionSSHKeyNotFound() throws {
        let error = NetworkError.sshKeyNotFound("/some/path/id_ed25519")
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(try #require(desc?.contains("/some/path/id_ed25519")))
    }

    @Test("guestIPNotFound error description is non-nil and mentions guest IP")
    func errorDescriptionGuestIPNotFound() throws {
        let error = NetworkError.guestIPNotFound
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(try #require(desc?.contains("guest")))
    }

    // MARK: - scanARPTableForMAC parser

    @Test("scanARPTableForMAC returns IP matching our MAC")
    func scanARPMatchesOurMAC() {
        let arpOutput = """
        ? (192.168.64.1) at 5a:41:b9:a0:5e:64 on bridge100 ifscope [ethernet]
        ? (192.168.64.8) at 2:da:72:56:0:1 on bridge100 ifscope [ethernet]
        ? (192.168.64.254) at ff:ff:ff:ff:ff:ff on bridge100 ifscope [ethernet]
        """
        let ip = NetworkManager.scanARPTableForMAC(arpOutput, expectedMAC: "02:da:72:56:00:01")
        #expect(ip == "192.168.64.8")
    }

    @Test("scanARPTableForMAC returns nil when MAC not present")
    func scanARPNoMatch() {
        let arpOutput = """
        ? (192.168.64.1) at 5a:41:b9:a0:5e:64 on bridge100 ifscope [ethernet]
        """
        let ip = NetworkManager.scanARPTableForMAC(arpOutput, expectedMAC: "02:da:72:56:00:01")
        #expect(ip == nil)
    }

    @Test("scanARPTableForMAC skips incomplete entries")
    func scanARPSkipsIncomplete() {
        let arpOutput = """
        ? (192.168.64.8) at (incomplete) on bridge100 ifscope [ethernet]
        """
        let ip = NetworkManager.scanARPTableForMAC(arpOutput, expectedMAC: "02:da:72:56:00:01")
        #expect(ip == nil)
    }

    @Test("scanARPTableForMAC handles normalized MAC input")
    func scanARPNormalizedInput() {
        let arpOutput = """
        ? (192.168.64.8) at 02:da:72:56:00:01 on bridge100 ifscope [ethernet]
        """
        let ip = NetworkManager.scanARPTableForMAC(arpOutput, expectedMAC: "2:da:72:56:0:1")
        #expect(ip == "192.168.64.8")
    }

    @Test("scanARPTableForMAC returns nil for empty input")
    func scanARPEmpty() {
        let ip = NetworkManager.scanARPTableForMAC("", expectedMAC: "02:da:72:56:00:01")
        #expect(ip == nil)
    }

    // MARK: - guestIPNotFound improved description

    @Test("guestIPNotFound description mentions bootpd and doctor command")
    func errorDescriptionGuestIPNotFoundMentionsBootpd() throws {
        let error = NetworkError.guestIPNotFound
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("bootpd"))
        #expect(desc.contains("darwin-vz-nix doctor"))
    }

    @Test("guestIPNotFound description lists multiple likely causes")
    func errorDescriptionGuestIPNotFoundListsCauses() throws {
        let desc = try #require(NetworkError.guestIPNotFound.errorDescription)
        #expect(desc.contains("Application Firewall"))
        #expect(desc.contains("DHCPDISCOVER"))
    }

    // MARK: - scanARPTableForMAC — additional edge cases

    @Test("scanARPTableForMAC returns first matching entry when multiple match")
    func scanARPReturnsFirstMatch() {
        let arpOutput = """
        ? (192.168.64.8) at 2:da:72:56:0:1 on bridge100 ifscope [ethernet]
        ? (192.168.64.42) at 2:da:72:56:0:1 on bridge100 ifscope [ethernet]
        """
        let ip = NetworkManager.scanARPTableForMAC(arpOutput, expectedMAC: "02:da:72:56:00:01")
        #expect(ip == "192.168.64.8")
    }

    @Test("scanARPTableForMAC skips lines without parenthesized IP")
    func scanARPSkipsLinesWithoutParens() {
        let arpOutput = """
        garbage line with no parens
        ? (192.168.64.8) at 2:da:72:56:0:1 on bridge100 ifscope [ethernet]
        """
        let ip = NetworkManager.scanARPTableForMAC(arpOutput, expectedMAC: "02:da:72:56:00:01")
        #expect(ip == "192.168.64.8")
    }

    @Test("scanARPTableForMAC skips lines missing ' at ' delimiter")
    func scanARPSkipsLinesMissingAt() {
        let arpOutput = """
        ? (192.168.64.8) on bridge100 ifscope [ethernet]
        ? (192.168.64.9) at 2:da:72:56:0:1 on bridge100 ifscope [ethernet]
        """
        let ip = NetworkManager.scanARPTableForMAC(arpOutput, expectedMAC: "02:da:72:56:00:01")
        #expect(ip == "192.168.64.9")
    }

    @Test("scanARPTableForMAC tolerates blank lines between entries")
    func scanARPToleratesBlankLines() {
        let arpOutput = "\n\n? (192.168.64.8) at 2:da:72:56:0:1 on bridge100 ifscope [ethernet]\n\n"
        let ip = NetworkManager.scanARPTableForMAC(arpOutput, expectedMAC: "02:da:72:56:00:01")
        #expect(ip == "192.168.64.8")
    }

    @Test("scanARPTableForMAC ignores non-matching entries and returns only when MAC matches")
    func scanARPIgnoresNonMatches() {
        let arpOutput = """
        ? (192.168.64.1) at 5a:41:b9:a0:5e:64 on bridge100 ifscope [ethernet]
        ? (192.168.64.2) at aa:bb:cc:dd:ee:ff on bridge100 ifscope [ethernet]
        ? (192.168.64.3) at 2:da:72:56:0:1 on bridge100 ifscope [ethernet]
        ? (192.168.64.4) at 5a:41:b9:a0:5e:65 on bridge100 ifscope [ethernet]
        """
        let ip = NetworkManager.scanARPTableForMAC(arpOutput, expectedMAC: "02:da:72:56:00:01")
        #expect(ip == "192.168.64.3")
    }

    // MARK: - parseLeaseContent — additional edge cases

    @Test("parseLeaseContent returns IP when notBefore equals the lease timestamp exactly")
    func parseLeaseContentNotBeforeEqual() {
        // notBefore uses strict-greater-than comparison, so equal means no match
        let ip = NetworkManager.parseLeaseContent(sampleLease, hostname: "darwin-vz-guest", notBefore: 0x6700_0001)
        #expect(ip == nil)
    }

    @Test("parseLeaseContent breaks ties using newestTimestamp >= comparison (later wins)")
    func parseLeaseContentEqualTimestampLaterWins() {
        let twoEqualLeases = """
        {
            name=darwin-vz-guest
            ip_address=192.168.64.2
            lease=0x67000050
        }
        {
            name=darwin-vz-guest
            ip_address=192.168.64.99
            lease=0x67000050
        }
        """
        let ip = NetworkManager.parseLeaseContent(twoEqualLeases, hostname: "darwin-vz-guest", notBefore: 0)
        #expect(ip == "192.168.64.99")
    }

    @Test("parseLeaseContent returns nil for a lease block missing ip_address")
    func parseLeaseContentMissingIP() {
        let noIP = """
        {
            name=darwin-vz-guest
            lease=0x67000001
        }
        """
        let ip = NetworkManager.parseLeaseContent(noIP, hostname: "darwin-vz-guest", notBefore: 0)
        #expect(ip == nil)
    }

    @Test("parseLeaseContent returns nil for a lease block missing lease timestamp")
    func parseLeaseContentMissingLease() {
        let noLease = """
        {
            name=darwin-vz-guest
            ip_address=192.168.64.2
        }
        """
        // lease=0 fails the `leaseTimestamp > notBefore` check when notBefore=0
        let ip = NetworkManager.parseLeaseContent(noLease, hostname: "darwin-vz-guest", notBefore: 0)
        #expect(ip == nil)
    }

    @Test("parseLeaseContent tolerates leading whitespace on field lines")
    func parseLeaseContentWhitespacePrefix() {
        let indented = """
        {
              name=darwin-vz-guest
              ip_address=192.168.64.2
              lease=0x67000001
        }
        """
        let ip = NetworkManager.parseLeaseContent(indented, hostname: "darwin-vz-guest", notBefore: 0)
        #expect(ip == "192.168.64.2")
    }

    // MARK: - normalizeMAC — additional edge cases

    @Test("normalizeMAC handles single-digit octets unchanged")
    func normalizeMACSingleDigitOctets() {
        #expect(NetworkManager.normalizeMAC("1:2:3:4:5:6") == "1:2:3:4:5:6")
    }

    @Test("normalizeMAC handles mixed case with leading zeros")
    func normalizeMACMixedCaseWithZeros() {
        #expect(NetworkManager.normalizeMAC("02:Da:72:56:00:0A") == "2:da:72:56:0:a")
    }

    @Test("normalizeMAC trims multiple leading zeros down to a single zero octet")
    func normalizeMACMultipleLeadingZeros() {
        #expect(NetworkManager.normalizeMAC("000:000:000:000:000:001") == "0:0:0:0:0:1")
    }
}
