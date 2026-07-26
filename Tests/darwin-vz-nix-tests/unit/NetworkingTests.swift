@testable import DarwinVZNixLib
import Foundation
import Testing

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

    @Test
    func parseLeaseContentMatchingHostname() {
        let ip = NetworkManager.parseLeaseContent(sampleLease, hostname: "darwin-vz-guest", unexpiredAt: 0)
        #expect(ip == "192.168.64.2")
    }

    // MARK: - parseLeaseContent non-matching hostname

    @Test
    func parseLeaseContentNonMatchingHostname() {
        let ip = NetworkManager.parseLeaseContent(sampleLease, hostname: "wrong-host", unexpiredAt: 0)
        #expect(ip == nil)
    }

    // MARK: - parseLeaseContent CRLF robustness

    /// A CRLF-terminated lease file must still parse: the per-line trim strips the
    /// trailing \r so `name==hostname` matches and the ip_address has no \r. Guards
    /// the whitespacesAndNewlines fix (\r is absent from CharacterSet.whitespaces).
    @Test
    func parseLeaseContentHandlesCRLF() {
        let crlf = sampleLease.replacingOccurrences(of: "\n", with: "\r\n")
        let ip = NetworkManager.parseLeaseContent(crlf, hostname: "darwin-vz-guest", unexpiredAt: 0)
        #expect(ip == "192.168.64.2")
    }

    // MARK: - parseLeaseContent expiration filter

    @Test
    func parseLeaseContentExpirationFilter() {
        let ip = NetworkManager.parseLeaseContent(multipleLeases, hostname: "darwin-vz-guest", unexpiredAt: 0x6700_0050)
        #expect(ip == "192.168.64.3")
    }

    @Test
    func parseLeaseContentExpirationFiltersAll() {
        let ip = NetworkManager.parseLeaseContent(sampleLease, hostname: "darwin-vz-guest", unexpiredAt: 0xFFFF_FFFF)
        #expect(ip == nil)
    }

    // MARK: - parseLeaseContent multiple leases

    @Test
    func parseLeaseContentSelectsNewest() {
        let ip = NetworkManager.parseLeaseContent(multipleLeases, hostname: "darwin-vz-guest", unexpiredAt: 0)
        #expect(ip == "192.168.64.3")
    }

    @Test
    func parseLeaseCandidatesReturnsAllMatchingUnexpiredLeasesDeterministically() {
        let candidates = NetworkManager.parseLeaseCandidates(
            multipleLeases,
            hostname: "darwin-vz-guest",
            unexpiredAt: 0
        )

        #expect(candidates.map(\.ip) == ["192.168.64.3", "192.168.64.2"])
    }

    @Test
    func verifiedLeaseCandidateProbesThenSelectsExpectedMAC() {
        let candidates = NetworkManager.parseLeaseCandidates(
            multipleLeases,
            hostname: "darwin-vz-guest",
            unexpiredAt: 0
        )
        var events: [String] = []

        let selected = NetworkManager.selectVerifiedLeaseCandidate(
            candidates,
            expectedMAC: "02:da:72:56:00:01",
            probe: { ip in
                events.append("probe:\(ip)")
                return true
            },
            verifyARP: { ip, mac in
                events.append("arp:\(ip):\(mac)")
                return ip == "192.168.64.2"
            }
        )

        #expect(selected == "192.168.64.2")
        #expect(events == [
            "probe:192.168.64.3",
            "arp:192.168.64.3:02:da:72:56:00:01",
            "probe:192.168.64.2",
            "arp:192.168.64.2:02:da:72:56:00:01",
        ])
    }

    @Test
    func verifiedLeaseCandidateRejectsARPMismatch() {
        let candidates = [NetworkManager.LeaseCandidate(ip: "192.168.64.2", expiration: 1, sourceOrder: 0)]

        let selected = NetworkManager.selectVerifiedLeaseCandidate(
            candidates,
            expectedMAC: "02:da:72:56:00:01",
            probe: { _ in true },
            verifyARP: { _, _ in false }
        )

        #expect(selected == nil)
    }

    @Test
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
        let ip = NetworkManager.parseLeaseContent(mixedLeases, hostname: "darwin-vz-guest", unexpiredAt: 0)
        #expect(ip == "192.168.64.2")
    }

    // MARK: - parseLeaseContent empty/malformed

    @Test
    func parseLeaseContentEmpty() {
        let ip = NetworkManager.parseLeaseContent("", hostname: "darwin-vz-guest", unexpiredAt: 0)
        #expect(ip == nil)
    }

    @Test
    func parseLeaseContentMalformed() {
        let malformed = "this is not a lease file at all"
        let ip = NetworkManager.parseLeaseContent(malformed, hostname: "darwin-vz-guest", unexpiredAt: 0)
        #expect(ip == nil)
    }

    // MARK: - normalizeMAC

    @Test
    func normalizeMACRemovesLeadingZeros() {
        #expect(NetworkManager.normalizeMAC("02:da:72:56:00:01") == "2:da:72:56:0:1")
    }

    @Test
    func normalizeMACAlreadyNormalized() {
        #expect(NetworkManager.normalizeMAC("2:da:72:56:0:1") == "2:da:72:56:0:1")
    }

    @Test
    func normalizeMACPreservesZero() {
        #expect(NetworkManager.normalizeMAC("00:00:00:00:00:00") == "0:0:0:0:0:0")
    }

    @Test
    func normalizeMACCaseInsensitive() {
        #expect(NetworkManager.normalizeMAC("02:DA:72:56:00:01") == "2:da:72:56:0:1")
    }

    // MARK: - NetworkError.errorDescription

    @Test
    func errorDescriptionSSHKeyGenerationFailed() throws {
        let error = NetworkError.sshKeyGenerationFailed(1)
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("1"))
        #expect(desc.contains("key generation"))
    }

    @Test
    func errorDescriptionSSHConnectionFailed() throws {
        let error = NetworkError.sshConnectionFailed(255)
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("255"))
        #expect(desc.contains("connection"))
    }

    @Test
    func errorDescriptionSSHKeyNotFound() throws {
        let error = NetworkError.sshKeyNotFound("/some/path/id_ed25519")
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("/some/path/id_ed25519"))
    }

    @Test
    func errorDescriptionGuestIPNotFound() throws {
        let error = NetworkError.guestIPNotFound
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("guest"))
    }

    // MARK: - scanARPTableForMAC parser

    @Test
    func scanARPMatchesOurMAC() {
        let arpOutput = """
        ? (192.168.64.1) at 5a:41:b9:a0:5e:64 on bridge100 ifscope [ethernet]
        ? (192.168.64.8) at 2:da:72:56:0:1 on bridge100 ifscope [ethernet]
        ? (192.168.64.254) at ff:ff:ff:ff:ff:ff on bridge100 ifscope [ethernet]
        """
        let ip = NetworkManager.scanARPTableForMAC(arpOutput, expectedMAC: "02:da:72:56:00:01")
        #expect(ip == "192.168.64.8")
    }

    @Test
    func scanARPNoMatch() {
        let arpOutput = """
        ? (192.168.64.1) at 5a:41:b9:a0:5e:64 on bridge100 ifscope [ethernet]
        """
        let ip = NetworkManager.scanARPTableForMAC(arpOutput, expectedMAC: "02:da:72:56:00:01")
        #expect(ip == nil)
    }

    @Test
    func scanARPSkipsIncomplete() {
        let arpOutput = """
        ? (192.168.64.8) at (incomplete) on bridge100 ifscope [ethernet]
        """
        let ip = NetworkManager.scanARPTableForMAC(arpOutput, expectedMAC: "02:da:72:56:00:01")
        #expect(ip == nil)
    }

    @Test
    func scanARPNormalizedInput() {
        let arpOutput = """
        ? (192.168.64.8) at 02:da:72:56:00:01 on bridge100 ifscope [ethernet]
        """
        let ip = NetworkManager.scanARPTableForMAC(arpOutput, expectedMAC: "2:da:72:56:0:1")
        #expect(ip == "192.168.64.8")
    }

    @Test
    func scanARPEmpty() {
        let ip = NetworkManager.scanARPTableForMAC("", expectedMAC: "02:da:72:56:00:01")
        #expect(ip == nil)
    }

    // MARK: - guestIPNotFound improved description

    @Test
    func errorDescriptionGuestIPNotFoundMentionsBootpd() throws {
        let error = NetworkError.guestIPNotFound
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("bootpd"))
        #expect(desc.contains("darwin-vz-nix doctor"))
    }

    @Test
    func errorDescriptionGuestIPNotFoundListsCauses() throws {
        let desc = try #require(NetworkError.guestIPNotFound.errorDescription)
        #expect(desc.contains("Application Firewall"))
        #expect(desc.contains("DHCPDISCOVER"))
    }

    // MARK: - scanARPTableForMAC — additional edge cases

    @Test
    func scanARPReturnsFirstMatch() {
        let arpOutput = """
        ? (192.168.64.8) at 2:da:72:56:0:1 on bridge100 ifscope [ethernet]
        ? (192.168.64.42) at 2:da:72:56:0:1 on bridge100 ifscope [ethernet]
        """
        let ip = NetworkManager.scanARPTableForMAC(arpOutput, expectedMAC: "02:da:72:56:00:01")
        #expect(ip == "192.168.64.8")
    }

    @Test
    func scanARPSkipsLinesWithoutParens() {
        let arpOutput = """
        garbage line with no parens
        ? (192.168.64.8) at 2:da:72:56:0:1 on bridge100 ifscope [ethernet]
        """
        let ip = NetworkManager.scanARPTableForMAC(arpOutput, expectedMAC: "02:da:72:56:00:01")
        #expect(ip == "192.168.64.8")
    }

    @Test
    func scanARPSkipsLinesMissingAt() {
        let arpOutput = """
        ? (192.168.64.8) on bridge100 ifscope [ethernet]
        ? (192.168.64.9) at 2:da:72:56:0:1 on bridge100 ifscope [ethernet]
        """
        let ip = NetworkManager.scanARPTableForMAC(arpOutput, expectedMAC: "02:da:72:56:00:01")
        #expect(ip == "192.168.64.9")
    }

    @Test
    func scanARPToleratesBlankLines() {
        let arpOutput = "\n\n? (192.168.64.8) at 2:da:72:56:0:1 on bridge100 ifscope [ethernet]\n\n"
        let ip = NetworkManager.scanARPTableForMAC(arpOutput, expectedMAC: "02:da:72:56:00:01")
        #expect(ip == "192.168.64.8")
    }

    @Test
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

    @Test
    func parseLeaseContentExpirationEqualIsExpired() {
        // `lease` is the expiration instant, so equality is no longer valid.
        let ip = NetworkManager.parseLeaseContent(sampleLease, hostname: "darwin-vz-guest", unexpiredAt: 0x6700_0001)
        #expect(ip == nil)
    }

    @Test
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
        let ip = NetworkManager.parseLeaseContent(twoEqualLeases, hostname: "darwin-vz-guest", unexpiredAt: 0)
        #expect(ip == "192.168.64.99")
    }

    @Test
    func parseLeaseContentMissingIP() {
        let noIP = """
        {
            name=darwin-vz-guest
            lease=0x67000001
        }
        """
        let ip = NetworkManager.parseLeaseContent(noIP, hostname: "darwin-vz-guest", unexpiredAt: 0)
        #expect(ip == nil)
    }

    @Test
    func parseLeaseContentMissingLease() {
        let noLease = """
        {
            name=darwin-vz-guest
            ip_address=192.168.64.2
        }
        """
        // Missing lease means expiration zero, which is not valid at time zero.
        let ip = NetworkManager.parseLeaseContent(noLease, hostname: "darwin-vz-guest", unexpiredAt: 0)
        #expect(ip == nil)
    }

    @Test
    func parseLeaseContentWhitespacePrefix() {
        let indented = """
        {
              name=darwin-vz-guest
              ip_address=192.168.64.2
              lease=0x67000001
        }
        """
        let ip = NetworkManager.parseLeaseContent(indented, hostname: "darwin-vz-guest", unexpiredAt: 0)
        #expect(ip == "192.168.64.2")
    }

    // MARK: - normalizeMAC — additional edge cases

    @Test
    func normalizeMACSingleDigitOctets() {
        #expect(NetworkManager.normalizeMAC("1:2:3:4:5:6") == "1:2:3:4:5:6")
    }

    @Test
    func normalizeMACMixedCaseWithZeros() {
        #expect(NetworkManager.normalizeMAC("02:Da:72:56:00:0A") == "2:da:72:56:0:a")
    }

    @Test
    func normalizeMACMultipleLeadingZeros() {
        #expect(NetworkManager.normalizeMAC("000:000:000:000:000:001") == "0:0:0:0:0:1")
    }

    // MARK: - isValidIPv4

    @Test
    func validIPv4Accepted() {
        #expect(NetworkManager.isValidIPv4("192.168.64.2"))
        #expect(NetworkManager.isValidIPv4("10.0.0.1"))
        #expect(NetworkManager.isValidIPv4("255.255.255.255"))
    }

    @Test
    func invalidIPv4Rejected() {
        #expect(!NetworkManager.isValidIPv4(""))
        #expect(!NetworkManager.isValidIPv4("not-an-ip"))
        #expect(!NetworkManager.isValidIPv4("256.1.1.1"))
        #expect(!NetworkManager.isValidIPv4("192.168.64"))
        #expect(!NetworkManager.isValidIPv4("192.168.64.2 ")) // trailing space
        #expect(!NetworkManager.isValidIPv4("::1")) // IPv6 is not IPv4
    }

    // MARK: - known_hosts policy

    @Test
    func knownHostsEntryLookupIgnoresCommentsAndBlankLines() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let knownHostsURL = tempDir.appendingPathComponent("known_hosts")
        try "\n# managed by darwin-vz-nix\n  # comment\n".write(
            to: knownHostsURL,
            atomically: true,
            encoding: .utf8
        )

        #expect(!NetworkManager.knownHostsContainsEntry(host: "darwin-vz-nix-state", at: knownHostsURL))
    }

    @Test
    func knownHostsEntryLookupRejectsUnrelatedLegacyIPPin() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let knownHostsURL = tempDir.appendingPathComponent("known_hosts")
        try "192.168.64.2 ssh-ed25519 key\n".write(
            to: knownHostsURL,
            atomically: true,
            encoding: .utf8
        )

        #expect(!NetworkManager.knownHostsContainsEntry(host: "darwin-vz-nix-state", at: knownHostsURL))
    }

    @Test
    func sshArgumentsPinStableAliasAcrossIPAddressChanges() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let manager = NetworkManager(stateDirectory: tempDir)
        try manager.ensureSSHKeys()
        try manager.writeGuestIP("192.168.64.2")

        let firstArguments = try manager.sshArguments()
        #expect(firstArguments.contains("HostKeyAlias=darwin-vz-nix-state"))
        #expect(firstArguments.contains("StrictHostKeyChecking=accept-new"))

        let knownHostsURL = manager.stateKnownHostsURL()
        try FileManager.default.createDirectory(
            at: knownHostsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "darwin-vz-nix-state ssh-ed25519 pinned-key\n".write(
            to: knownHostsURL,
            atomically: true,
            encoding: .utf8
        )
        try manager.writeGuestIP("192.168.64.99")

        let restartedArguments = try manager.sshArguments()
        #expect(restartedArguments.contains("HostKeyAlias=darwin-vz-nix-state"))
        #expect(restartedArguments.contains("StrictHostKeyChecking=yes"))
        #expect(restartedArguments.contains("builder@192.168.64.99"))
    }

    // MARK: - Per-instance MAC derivation

    @Test
    func macAddressIsDeterministicPerStateDir() {
        let dir = URL(fileURLWithPath: "/Users/test/.local/share/darwin-vz-nix")
        let a = VMConfig.macAddress(for: dir)
        let b = VMConfig.macAddress(for: dir)
        #expect(a == b)
    }

    @Test
    func macAddressDiffersAcrossStateDirs() {
        let a = VMConfig.macAddress(for: URL(fileURLWithPath: "/tmp/vm-a"))
        let b = VMConfig.macAddress(for: URL(fileURLWithPath: "/tmp/vm-b"))
        #expect(a != b)
    }

    @Test
    func macAddressIsLocallyAdministeredUnicast() {
        let mac = VMConfig.macAddress(for: URL(fileURLWithPath: "/tmp/vm-a"))
        #expect(mac.hasPrefix("02:da:72:"))
        // Six colon-separated hex octets.
        let octets = mac.split(separator: ":")
        #expect(octets.count == 6)
        #expect(octets.allSatisfy { UInt8($0, radix: 16) != nil })
    }
}
