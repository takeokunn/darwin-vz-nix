{ ... }:

{
  # Root filesystem on virtio block device
  fileSystems."/" = {
    device = "/dev/vda";
    fsType = "ext4";
    autoResize = true;
  };

  # VirtioFS: host's /nix/store (read-only lower layer)
  fileSystems."/nix/.ro-store" = {
    device = "nix-store"; # Cross-language contract: must match Constants.nixStoreTag in Swift
    fsType = "virtiofs";
    options = [ "ro" ];
    neededForBoot = true;
  };

  # Overlay: merge host's read-only store with disk-backed writable layer
  # Upper layer uses the root ext4 filesystem (/dev/vda) instead of tmpfs
  # to prevent OOM during heavy builds (build artifacts go to disk, not RAM).
  # The initrd creates /nix/.rw-store/{store,work} and /nix/var/nix/db
  # directories on root via postMountCommands (see boot.nix).
  fileSystems."/nix/store" = {
    fsType = "overlay";
    device = "overlay";
    options = [
      "lowerdir=/nix/.ro-store"
      "upperdir=/nix/.rw-store/store"
      "workdir=/nix/.rw-store/work"
    ];
    depends = [
      "/nix/.ro-store"
    ];
    neededForBoot = true;
  };
}
