{
  pkgs,
  lib,
  ...
}:

{
  # No bootloader - direct kernel boot via VZLinuxBootLoader
  boot.loader.grub.enable = false;

  # Mount /nix/store as writable. Our overlay (host VirtioFS as lowerdir +
  # tmpfs upperdir) provides the writable layer the nix-daemon needs.
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

  # Extra utilities needed in initrd for first-boot disk formatting
  # Use mke2fs directly (mkfs.ext4 is a symlink that copy_bin_and_libs may not handle)
  boot.initrd.extraUtilsCommands = ''
    copy_bin_and_libs ${pkgs.e2fsprogs}/bin/mke2fs
    copy_bin_and_libs ${pkgs.util-linux}/bin/blkid
  '';

  # Auto-format root disk on first boot
  boot.initrd.postDeviceCommands = lib.mkBefore ''
    if ! blkid /dev/vda &>/dev/null; then
      echo "First boot: formatting /dev/vda as ext4..."
      mke2fs -t ext4 -L root /dev/vda
    fi
  '';

  # LZ4 compression for initrd (legacy format for kernel compatibility)
  boot.initrd.compressor = lib.getExe pkgs.lz4;
  boot.initrd.compressorArgs = [
    "-l"
  ];
}
