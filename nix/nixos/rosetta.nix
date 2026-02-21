{
  config,
  pkgs,
  lib,
  ...
}:

{
  # Rosetta 2 for x86_64-linux binary execution
  # Uses NixOS built-in virtualisation.rosetta module
  # The "rosetta" tag must match the Swift VirtioFS tag exactly
  virtualisation.rosetta.enable = true;
  virtualisation.rosetta.mountTag = "rosetta";

  # The virtualisation.rosetta module automatically:
  # - Mounts the Rosetta runtime at /run/rosetta via VirtioFS
  # - Registers rosetta as binfmt_misc handler for x86_64 ELF binaries
  # - Adds x86_64-linux to nix.settings.extra-platforms
  # - Adds /run/rosetta and /run/binfmt to nix.settings.extra-sandbox-paths
}
