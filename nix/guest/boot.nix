{
  pkgs,
  lib,
  ...
}:

{
  # No bootloader - direct kernel boot via VZLinuxBootLoader
  boot.loader.grub.enable = false;

  # Mount /nix/store as writable. Our overlay (host VirtioFS as lowerdir +
  # root-disk upperdir) provides the writable layer the nix-daemon needs.
  # Without this, NixOS remounts the overlay as read-only and lock file
  # creation in /nix/store fails with "Permission denied".
  boot.nixStoreMountOpts = [ "rw" ];

  # Kernel configuration for Virtualization.framework
  boot.kernelParams = [ "console=hvc0" ];

  boot.initrd.availableKernelModules = [
    "virtiofs"
    "virtio_pci"
    "virtio_blk"
    "virtio_net"
    "virtio_balloon"
    "virtio_console"
    "virtio_rng"
    "overlay"
  ];

  # Create the overlay's writable upper/work directories on the root disk BEFORE
  # the /nix/store overlay is mounted in the initrd. The overlay mount
  # (neededForBoot) appears as `sysroot-nix-store.mount`; without an explicit
  # ordering edge the mount could race ahead of directory creation and fail.
  boot.initrd.systemd.services.prepare-nix-var = {
    description = "Prepare writable Nix state directories";
    requiredBy = [
      "initrd-switch-root.target"
      "sysroot-nix-store.mount"
    ];
    before = [
      "initrd-switch-root.target"
      "sysroot-nix-store.mount"
    ];
    after = [ "sysroot.mount" ];
    unitConfig = {
      DefaultDependencies = false;
      RequiresMountsFor = "/sysroot";
    };
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /sysroot/nix/var/nix/db
      mkdir -p /sysroot/nix/.rw-store/store
      mkdir -p /sysroot/nix/.rw-store/work
    '';
  };

  # LZ4 compression for initrd (legacy format for kernel compatibility)
  boot.initrd.compressor = lib.getExe pkgs.lz4;
  boot.initrd.compressorArgs = [
    "-l"
  ];
}
