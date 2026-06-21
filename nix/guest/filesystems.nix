{ ... }:

{
  # Root filesystem on virtio block device
  fileSystems."/" = {
    device = "/dev/vda";
    fsType = "ext4";
    autoFormat = true;
    autoResize = true;
  };

  # Periodically TRIM the guest filesystem so blocks freed by Nix GC are punched
  # out of the host's sparse disk.img (reclaiming host disk), instead of the
  # image growing monotonically. Uses fstrim rather than continuous `discard`
  # to avoid per-delete overhead during heavy builds.
  services.fstrim.enable = true;

  # VirtioFS: host's /nix/store (read-only lower layer)
  fileSystems."/nix/.ro-store" = {
    device = "nix-store"; # Cross-language contract: must match Constants.nixStoreTag in Swift
    fsType = "virtiofs";
    options = [ "ro" ];
    neededForBoot = true;
  };

  # Overlay: merge host's read-only store with disk-backed writable layer.
  # Upper layer uses the root ext4 filesystem (/dev/vda) instead of tmpfs
  # to prevent OOM during heavy builds (build artifacts go to disk, not RAM).
  # The upper/work directories are created by the initrd `prepare-nix-var`
  # service (see boot.nix), which is ordered before this mount.
  fileSystems."/nix/store" = {
    fsType = "overlay";
    device = "overlay";
    overlay.lowerdir = [ "/nix/.ro-store" ];
    overlay.upperdir = "/nix/.rw-store/store";
    overlay.workdir = "/nix/.rw-store/work";
    neededForBoot = true;
  };
}
