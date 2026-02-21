{
  modulesPath,
  ...
}:

{
  imports = [
    "${modulesPath}/profiles/minimal.nix"
    ./boot.nix
    ./filesystems.nix
    ./networking.nix
    ./builder.nix
    ./rosetta.nix
  ];
}
