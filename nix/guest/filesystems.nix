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

  # Writable upper layer for overlay (tmpfs)
  fileSystems."/nix/.rw-store" = {
    fsType = "tmpfs";
    options = [ "mode=0755" ];
    neededForBoot = true;
  };

  # Nix store database on tmpfs to match volatile overlay upper layer
  # Without this, the DB persists across reboots while tmpfs data is lost,
  # causing "No such file or directory" errors for .drv files that are
  # registered in the DB but no longer exist on the filesystem.
  fileSystems."/nix/var/nix/db" = {
    fsType = "tmpfs";
    options = [ "mode=0755" ];
    neededForBoot = true;
  };

  # Overlay: merge host's read-only store with writable tmpfs layer
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
      "/nix/.rw-store"
    ];
    neededForBoot = true;
  };
}
