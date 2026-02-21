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
    nur-packages = {
      url = "github:takeokunn/nur-packages";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-linux,
      nur-packages,
    }:
    let
      # Only aarch64-darwin is supported
      system = "aarch64-darwin";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      nurPkgs = nur-packages.legacyPackages.${system};
      linuxSystem = "aarch64-linux";
      darwinVzNix = pkgs.callPackage ./nix/package.nix {
        swift-bin = nurPkgs.swift-bin;
        swift-argument-parser-src = nurPkgs.swift-argument-parser;
        swift-testing-src = nurPkgs.swift-testing;
        swift-syntax-src = nurPkgs.swift-syntax;
      };
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
          ./nix/guest
        ];
      };

      # Guest artifacts (kernel + initrd) as packages
      packages.${linuxSystem} = {
        guest-kernel = self.nixosConfigurations.darwin-vz-guest.config.system.build.kernel;
        guest-initrd = self.nixosConfigurations.darwin-vz-guest.config.system.build.initialRamdisk;
        guest-system = self.nixosConfigurations.darwin-vz-guest.config.system.build.toplevel;
      };

      # nix-darwin module
      darwinModules.default = {
        imports = [ ./nix/host/darwin-module.nix ];
        config.services.darwin-vz.package = lib.mkDefault darwinVzNix;
      };

      # Checks (built by `nix flake check` on aarch64-linux CI)
      checks.${linuxSystem} = {
        guest-kernel = self.packages.${linuxSystem}.guest-kernel;
        guest-initrd = self.packages.${linuxSystem}.guest-initrd;
        guest-system = self.packages.${linuxSystem}.guest-system;
      };

      # Checks for aarch64-darwin
      checks.${system} = {
        swift-test = darwinVzNix.overrideAttrs (_: {
          name = "darwin-vz-nix-test";
          buildPhase = ''
            runHook preBuild
            export HOME=$TMPDIR
            unset SDKROOT DEVELOPER_DIR
            export SDKROOT=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
            export NIX_ENFORCE_PURITY=0
            swift test --disable-sandbox
            runHook postBuild
          '';
          installPhase = ''
            touch $out
          '';
          postFixup = "";
        });
        formatting =
          let
            src = lib.cleanSourceWith {
              src = ./.;
              filter =
                path: _type:
                let
                  baseName = builtins.baseNameOf path;
                in
                !(baseName == ".git" || baseName == ".build" || baseName == ".swiftpm" || baseName == "result");
            };
          in
          pkgs.runCommand "check-formatting" { } ''
            find ${src} -name '*.nix' -exec ${pkgs.nixfmt}/bin/nixfmt --check {} +
            ${pkgs.swiftformat}/bin/swiftformat --lint ${src}/Sources ${src}/Tests
            touch $out
          '';
      };

      # Formatter
      formatter.${system} = pkgs.nixfmt-tree;

      # Dev shell for Swift development
      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs = [
          nurPkgs.swift-bin
          pkgs.swiftformat
          pkgs.nixfmt
        ];
        shellHook = ''
          echo "darwin-vz-nix development shell"
          echo "  swift: $(swift --version 2>&1 | head -1)"
          echo "  swiftformat: $(swiftformat --version)"
          echo ""
          echo "Commands:"
          echo "  swift build                Build Swift project"
          echo "  swift test                 Run Swift tests"
          echo "  nix build                  Build darwin-vz-nix package"
          echo "  nix flake check            Run all checks (tests + formatting)"
          echo "  nix fmt                    Format Nix files"
          echo ""
          echo "Quick start (run a NixOS VM):"
          echo "  nix build .#packages.aarch64-linux.guest-kernel -o result-kernel --max-jobs 0 --option extra-platforms aarch64-linux --option always-allow-substitutes true"
          echo "  nix build .#packages.aarch64-linux.guest-initrd -o result-initrd --max-jobs 0 --option extra-platforms aarch64-linux --option always-allow-substitutes true"
          echo "  nix build .#packages.aarch64-linux.guest-system -o result-system --max-jobs 0 --option extra-platforms aarch64-linux --option always-allow-substitutes true"
          echo "  nix run .#darwin-vz-nix -- start --kernel ./result-kernel/Image --initrd ./result-initrd/initrd --system ./result-system"
          echo "  nix run .#darwin-vz-nix -- ssh"
          echo "  nix run .#darwin-vz-nix -- stop"
        '';
      };
    };
}
