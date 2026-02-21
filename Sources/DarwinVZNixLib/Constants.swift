import Foundation

/// Centralized constants for darwin-vz-nix.
/// Cross-language contracts: VirtioFS tags and hostname must match their
/// Nix counterparts exactly. See the doc comments for each constant.
enum Constants {
    // MARK: - VirtioFS Tags (Cross-Language Contract)

    // These tags are used in VZVirtioFileSystemDeviceConfiguration and must
    // match the corresponding mount tags in the NixOS guest configuration.

    /// VirtioFS tag for sharing host's /nix/store with the guest.
    /// Nix counterpart: nix/guest/filesystems.nix — fileSystems."/nix/.ro-store".device
    static let nixStoreTag = "nix-store"

    /// VirtioFS tag for Rosetta 2 runtime sharing.
    /// Nix counterpart: nix/guest/rosetta.nix — virtualisation.rosetta.mountTag
    static let rosettaTag = "rosetta"

    /// VirtioFS tag for sharing SSH keys with the guest.
    /// Nix counterpart: nix/guest/builder.nix — fileSystems."/run/ssh-keys".device
    static let sshKeysTag = "ssh-keys"

    // MARK: - Network Constants (Cross-Language Contract)

    /// Guest hostname used for DHCP lease discovery.
    /// Nix counterpart: nix/guest/networking.nix — networking.hostName
    static let guestHostname = "darwin-vz-guest"

    /// Deterministic locally-administered MAC address for the VM.
    /// "02" = locally administered + unicast; "da:72:56" = mnemonic for "darVZ".
    static let macAddressString = "02:da:72:56:00:01"
}
