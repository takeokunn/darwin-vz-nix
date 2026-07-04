{ lib, ... }:

{
  # Rosetta 2 for x86_64-linux binary execution
  # The "rosetta" tag is a cross-language contract: must match Constants.rosettaTag in Swift
  virtualisation.rosetta.enable = true;
  virtualisation.rosetta.mountTag = "rosetta";

  # The virtualisation.rosetta module automatically:
  # - Mounts the Rosetta runtime at /run/rosetta via VirtioFS
  # - Registers rosetta as binfmt_misc handler for x86_64 ELF binaries
  # - Adds x86_64-linux to nix.settings.extra-platforms
  # - Adds /run/rosetta and /run/binfmt to nix.settings.extra-sandbox-paths

  # The guest is a static build that always expects the "rosetta" VirtioFS share,
  # but the host can withhold it (`start --no-rosetta`, or the darwin module with
  # `rosetta = false`). Without `nofail`, that absent share leaves /run/rosetta a
  # failed mount unit and marks the whole system `degraded`. `nofail` lets the
  # mount be skipped cleanly when the share is missing, so `--no-rosetta` still
  # yields a healthy guest (aarch64 builds work; x86_64 emulation is simply off).
  fileSystems."/run/rosetta".options = lib.mkForce [
    "defaults"
    "nofail"
  ];
}
