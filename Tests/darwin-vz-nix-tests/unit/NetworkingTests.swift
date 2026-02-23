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
}
