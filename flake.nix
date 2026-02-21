{
  description = "Swift CLI + nix-darwin module for NixOS VMs via macOS Virtualization.framework";

  nixConfig = {
    extra-substituters = [ "https://takeokunn-darwin-vz-nix.cachix.org" ];
    extra-trusted-public-keys = [
      "takeokunn-darwin-vz-nix.cachix.org-1:/JRjcn9UMUbE0DRyJUg7g+gq/e7QSUXxvz+FZprHIH4="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # For NixOS guest image building
    nixpkgs-linux.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-linux,
    }:
    let
      # Only aarch64-darwin is supported
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      linuxSystem = "aarch64-linux";
    in
    let
      darwinVzNix = pkgs.callPackage ./nix/package.nix { };
    in
    {
      # Swift CLI package
      packages.${system} = {
        default = darwinVzNix;
        darwin-vz-nix = darwinVzNix;
      };

      # NixOS guest configuration
      nixosConfigurations.darwin-vz-guest = nixpkgs-linux.lib.nixosSystem {
        system = linuxSystem;
        modules = [
          ./nix/nixos/configuration.nix
        ];
      };

      # Guest artifacts (kernel + initrd) as packages
      packages.${linuxSystem} = {
        guest-kernel =
          self.nixosConfigurations.darwin-vz-guest.config.system.build.kernel;
        guest-initrd =
          self.nixosConfigurations.darwin-vz-guest.config.system.build.initialRamdisk;
        guest-system =
          self.nixosConfigurations.darwin-vz-guest.config.system.build.toplevel;
      };

      # nix-darwin module
      darwinModules.default = import ./nix/darwin-module.nix;

      # Checks (built by `nix flake check` on aarch64-linux CI)
      checks.${linuxSystem} = {
        guest-kernel = self.packages.${linuxSystem}.guest-kernel;
        guest-initrd = self.packages.${linuxSystem}.guest-initrd;
      };

      # Formatter
      formatter.${system} = pkgs.nixfmt-tree;

      # Dev shell for Swift development
      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs = with pkgs; [
          swift
          swiftpm
          swiftformat
          sourcekit-lsp
        ];
      };
    };
}
