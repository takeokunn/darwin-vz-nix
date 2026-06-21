{ ... }:

{
  # Networking via systemd-networkd (DHCP from NAT)
  systemd.network = {
    enable = true;
    networks."10-virtio" = {
      matchConfig.Driver = "virtio_net";
      # Use DNS provided by the NAT DHCP server rather than hardcoding public
      # resolvers; this respects the host's network/split-DNS configuration.
      networkConfig.DHCP = "yes";
      # Explicitly send hostname in DHCP requests to ensure macOS's vmnet
      # DHCP server records it in /var/db/dhcpd_leases. This enables the
      # host to discover the guest IP by matching the hostname.
      # Cross-language contract: must match Constants.guestHostname in Swift.
      dhcpV4Config = {
        Hostname = "darwin-vz-guest";
        UseHostname = false; # Don't let DHCP server override our static hostname
      };
    };
  };
  networking.useNetworkd = true;
  networking.hostName = "darwin-vz-guest"; # Cross-language contract: must match Constants.guestHostname in Swift
}
