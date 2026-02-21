{ ... }:

{
  # Networking via systemd-networkd (DHCP from NAT)
  systemd.network = {
    enable = true;
    networks."10-virtio" = {
      matchConfig.Driver = "virtio_net";
      networkConfig = {
        DHCP = "yes";
        DNS = [
          "8.8.8.8"
          "8.8.4.4"
        ];
      };
    };
  };
  networking.useNetworkd = true;
  networking.hostName = "darwin-vz-guest"; # Cross-language contract: must match Constants.guestHostname in Swift
}
