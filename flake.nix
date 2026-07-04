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
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
      nix-darwin,
      nur-packages,
    }:
    let
      # Only aarch64-darwin is supported
      system = "aarch64-darwin";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      nurPkgs = nur-packages.legacyPackages.${system};
      linuxSystem = "aarch64-linux";
      linuxPkgs = nixpkgs-linux.legacyPackages.${linuxSystem};

      # The upstream swift-bin .pkg payload ships macOS AppleDouble resource-fork
      # files (._*). Swift's cross-import overlay resolver otherwise discovers
      # e.g. Testing.swiftcrossimport/._Foundation.swiftoverlay as a phantom
      # "._Foundation" module and fails parsing the binary as YAML — which breaks
      # `swift test` entirely. Strip them so the toolchain is usable for testing.
      # All consumers (package build, test check, devShell) MUST use this wrapper.
      swiftBin = nurPkgs.swift-bin.overrideAttrs (old: {
        installPhase = (old.installPhase or "") + ''

          # Strip macOS AppleDouble resource-fork files (._*) that pollute the .pkg payload.
          # Swift's cross-import overlay resolver otherwise discovers e.g.
          # Testing.swiftcrossimport/._Foundation.swiftoverlay as a phantom '._Foundation'
          # module and fails parsing the binary as YAML, breaking `swift test`.
          find "$out" -name '._*' -type f -delete
        '';
      });

      darwinVzNix = pkgs.callPackage ./nix/package.nix {
        swift-bin = swiftBin;
        swift-argument-parser-src = nurPkgs.swift-argument-parser;
      };
      buildGuestArtifactsApp = appPkgs: {
        type = "app";
        program = "${appPkgs.writeShellScriptBin "build-guest-artifacts" ''
                      set -euo pipefail

                      usage() {
                        cat <<EOF
          Usage: build-guest-artifacts [--out-dir DIR] [--from-closure-manifest FILE]

          Builds or fetches the aarch64-linux guest kernel, initrd, system
          toplevel, and bundled artifact output. DIR defaults to the current
          directory, or DARWIN_VZ_NIX_ARTIFACT_DIR when set.

          --from-closure-manifest materializes links from an already imported
          nix-store -qR manifest. It is intended for CI handoff from Linux to
          macOS runners and does not try to build guest artifacts.
          EOF
                      }

                      OUTPUT_DIR=''${DARWIN_VZ_NIX_ARTIFACT_DIR:-$PWD}
                      CLOSURE_MANIFEST=
                      while [ "$#" -gt 0 ]; do
                        case "$1" in
                          --out-dir)
                            if [ "$#" -lt 2 ]; then
                              echo "--out-dir requires a directory" >&2
                              exit 2
                            fi
                            OUTPUT_DIR="$2"
                            shift 2
                            ;;
                          --from-closure-manifest)
                            if [ "$#" -lt 2 ]; then
                              echo "--from-closure-manifest requires a file" >&2
                              exit 2
                            fi
                            CLOSURE_MANIFEST="$2"
                            shift 2
                            ;;
                          --help|-h)
                            usage
                            exit 0
                            ;;
                          *)
                            echo "Unknown argument: $1" >&2
                            usage >&2
                            exit 2
                            ;;
                        esac
                      done

                      mkdir -p "$OUTPUT_DIR"
                      OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
                      FLAKE_REF=${lib.escapeShellArg self.outPath}

                      NIX_FLAGS=(
                        --accept-flake-config
                        --option always-allow-substitutes true
                        --option builders-use-substitutes true
                        --print-build-logs
                      )

                      show_nix_setting() {
                        local key="$1"
                        {
                          nix config show 2>/dev/null || nix show-config 2>/dev/null
                        } | sed -n "s/^$key = //p" | head -n 1
                      }

                      host_system() {
                        local configured
                        configured=$(show_nix_setting system)
                        if [ -n "$configured" ]; then
                          printf '%s\n' "$configured"
                          return
                        fi

                        nix eval --raw --impure --expr builtins.currentSystem 2>/dev/null || true
                      }

                      can_build_aarch64_linux_locally() {
                        [ "$(host_system)" = "aarch64-linux" ]
                      }

                      configured_builders() {
                        local builders
                        builders=$(show_nix_setting builders)

                        if [ -n "$builders" ]; then
                          printf '%s\n' "$builders"
                          return
                        fi

                        if [ -s /etc/nix/machines ]; then
                          tr '\n' ';' < /etc/nix/machines
                          printf '\n'
                          return
                        fi

                        printf 'none\n'
                      }

                      has_aarch64_linux_builder() {
                        local builders
                        builders=$(configured_builders)
                        [ "$builders" != "none" ] && printf '%s\n' "$builders" | grep -q 'aarch64-linux'
                      }

                      print_required_builds() {
                        awk '
                          /derivation(s)? will be built:/ {
                            printing = 1
                            count = 0
                            print
                            next
                          }
                          printing && /path(s)? will be fetched/ {
                            printing = 0
                            next
                          }
                          printing && count < 25 {
                            print
                            count++
                            next
                          }
                          printing && count == 25 {
                            print "  ..."
                            count++
                            next
                          }
                        '
                      }

                      check_artifact_available_without_builder() {
                        local name="$1"
                        local attr="$2"
                        local dry_run_output

                        if ! dry_run_output=$(nix build "$FLAKE_REF#packages.aarch64-linux.$attr" --dry-run "''${NIX_FLAGS[@]}" 2>&1); then
                          printf '%s\n' "$dry_run_output" >&2
                          echo "Failed to evaluate whether $name can be fetched from configured substituters." >&2
                          exit 1
                        fi

                        if printf '%s\n' "$dry_run_output" | grep -Eq 'derivation(s)? will be built'; then
                          echo "" >&2
                          echo "$name is not fully available from the configured substituters." >&2
                          printf '%s\n' "$dry_run_output" | print_required_builds >&2
                          missing_cached_artifacts=1
                        fi
                      }

                      preflight_without_builder() {
                        missing_cached_artifacts=0
                        echo "Preflighting bundled guest artifacts against configured substituters..."
                        check_artifact_available_without_builder guest-artifacts guest-artifacts

                        if [ "$missing_cached_artifacts" -ne 0 ]; then
                          cat >&2 <<EOF

          Guest artifacts are missing from the configured binary caches, and this
          Darwin host has no usable aarch64-linux builder.

          No partial result links were written. Run this on an aarch64-linux
          machine, configure a remote Linux builder, or push the updated guest
          artifacts from CI to Cachix before running this command on Darwin.
          EOF
                          exit 1
                        fi
                      }

                      replace_link() {
                        local link_path="$1"
                        local target="$2"

                        if [ -e "$link_path" ] && [ ! -L "$link_path" ]; then
                          echo "Refusing to replace non-symlink path: $link_path" >&2
                          exit 1
                        fi

                        rm -f "$link_path"
                        ln -s "$target" "$link_path"
                      }

                      require_regular_file() {
                        local path="$1"

                        if [ ! -f "$path" ]; then
                          echo "Expected regular file: $path" >&2
                          exit 1
                        fi
                      }

                      require_executable() {
                        local path="$1"

                        if [ ! -x "$path" ]; then
                          echo "Expected executable: $path" >&2
                          exit 1
                        fi
                      }

                      validate_guest_artifact_links() {
                        require_regular_file "$OUTPUT_DIR/result-kernel/Image"
                        require_regular_file "$OUTPUT_DIR/result-initrd/initrd"
                        require_executable "$OUTPUT_DIR/result-system/init"
                        require_regular_file "$OUTPUT_DIR/result-guest-artifacts/Image"
                        require_regular_file "$OUTPUT_DIR/result-guest-artifacts/initrd"
                        require_executable "$OUTPUT_DIR/result-guest-artifacts/system/init"
                      }

                      link_bundled_artifacts() {
                        local bundle
                        bundle=$(readlink "$OUTPUT_DIR/result-guest-artifacts")

                        replace_link "$OUTPUT_DIR/result-kernel" "$bundle"
                        replace_link "$OUTPUT_DIR/result-initrd" "$bundle"
                        replace_link "$OUTPUT_DIR/result-system" "$bundle/system"

                        validate_guest_artifact_links
                      }

                      materialize_from_closure_manifest() {
                        local manifest="$1"
                        local bundle=
                        local candidate

                        if [ ! -f "$manifest" ]; then
                          echo "Closure manifest does not exist: $manifest" >&2
                          exit 1
                        fi

                        while IFS= read -r candidate; do
                          case "$candidate" in
                            /nix/store/*-darwin-vz-nix-guest-artifacts)
                              if [ -n "$bundle" ]; then
                                echo "Multiple guest artifact bundles found in closure manifest:" >&2
                                echo "  $bundle" >&2
                                echo "  $candidate" >&2
                                exit 1
                              fi
                              bundle="$candidate"
                              ;;
                            "")
                              ;;
                            /nix/store/*)
                              ;;
                            *)
                              echo "Unexpected non-store path in closure manifest: $candidate" >&2
                              exit 1
                              ;;
                          esac
                        done < "$manifest"

                        if [ -z "$bundle" ]; then
                          echo "No darwin-vz-nix guest artifact bundle found in closure manifest: $manifest" >&2
                          exit 1
                        fi

                        nix-store --verify-path "$bundle"
                        require_regular_file "$bundle/Image"
                        require_regular_file "$bundle/initrd"
                        require_executable "$bundle/system/init"

                        replace_link "$OUTPUT_DIR/result-guest-artifacts" "$bundle"
                        link_bundled_artifacts
                      }

                      echo "Preparing aarch64-linux guest artifacts in $OUTPUT_DIR"

                      if [ -n "$CLOSURE_MANIFEST" ]; then
                        echo "Materializing guest artifacts from closure manifest: $CLOSURE_MANIFEST"
                        materialize_from_closure_manifest "$CLOSURE_MANIFEST"

                        echo ""
                        echo "All guest artifacts materialized successfully:"
                        echo "  $OUTPUT_DIR/result-kernel -> $(readlink "$OUTPUT_DIR/result-kernel")"
                        echo "  $OUTPUT_DIR/result-initrd -> $(readlink "$OUTPUT_DIR/result-initrd")"
                        echo "  $OUTPUT_DIR/result-system -> $(readlink "$OUTPUT_DIR/result-system")"
                        echo "  $OUTPUT_DIR/result-guest-artifacts -> $(readlink "$OUTPUT_DIR/result-guest-artifacts")"
                        exit 0
                      fi

                      echo "Host system: $(host_system)"
                      echo "Configured substituters: $(show_nix_setting substituters)"
                      echo "Configured builders: $(configured_builders)"

                      NO_USABLE_AARCH64_LINUX_BUILDER=0
                      if ! can_build_aarch64_linux_locally && ! has_aarch64_linux_builder; then
                        NO_USABLE_AARCH64_LINUX_BUILDER=1
                        cat >&2 <<EOF
          No usable aarch64-linux builder was found in Nix configuration.

          This is fine when the bundled artifacts are already in Cachix or were
          imported into the local Nix store. If the current flake lock has not
          been pushed to Cachix yet, this Darwin host will not be able to build
          guest-initrd or guest-system by itself.

          To build locally on macOS, first configure an aarch64-linux remote builder
          or run this command on an aarch64-linux machine.
          EOF
                        preflight_without_builder
                      fi

                      build_artifact() {
                        local name="$1"
                        local attr="$2"
                        local link_name="$3"
                        shift 3

                        echo "Building $name..."
                        if ! nix build "$FLAKE_REF#packages.aarch64-linux.$attr" -o "$OUTPUT_DIR/$link_name" "''${NIX_FLAGS[@]}"; then
                          cat >&2 <<EOF

          Failed to build $name.

          These guest artifacts target aarch64-linux. On Darwin this command can only
          fetch them from a configured binary cache or ask a configured aarch64-linux
          remote builder to build them.

          Configured substituters: $(show_nix_setting substituters)
          Configured builders: $(configured_builders)

          Run this on an aarch64-linux machine, configure a remote Linux builder, or push
          the updated guest artifacts from the main CI workflow to Cachix.
          EOF
                          exit 1
                        fi

                        local expected_file
                        for expected_file in "$@"; do
                          if [ ! -e "$OUTPUT_DIR/$link_name/$expected_file" ]; then
                            echo "Expected $OUTPUT_DIR/$link_name/$expected_file to exist after building $name" >&2
                            exit 1
                          fi
                        done
                      }

                      if [ "$NO_USABLE_AARCH64_LINUX_BUILDER" -eq 1 ]; then
                        build_artifact guest-artifacts guest-artifacts result-guest-artifacts Image initrd system/init
                        link_bundled_artifacts

                        echo ""
                        echo "All guest artifacts built successfully:"
                        echo "  $OUTPUT_DIR/result-kernel -> $(readlink "$OUTPUT_DIR/result-kernel")"
                        echo "  $OUTPUT_DIR/result-initrd -> $(readlink "$OUTPUT_DIR/result-initrd")"
                        echo "  $OUTPUT_DIR/result-system -> $(readlink "$OUTPUT_DIR/result-system")"
                        echo "  $OUTPUT_DIR/result-guest-artifacts -> $(readlink "$OUTPUT_DIR/result-guest-artifacts")"
                        exit 0
                      fi

                      build_artifact guest-kernel guest-kernel result-kernel Image
                      build_artifact guest-initrd guest-initrd result-initrd initrd
                      build_artifact guest-system guest-system result-system init
                      build_artifact guest-artifacts guest-artifacts result-guest-artifacts Image initrd system/init
                      validate_guest_artifact_links

                      echo ""
                      echo "All guest artifacts built successfully:"
                      echo "  $OUTPUT_DIR/result-kernel -> $(readlink "$OUTPUT_DIR/result-kernel")"
                      echo "  $OUTPUT_DIR/result-initrd -> $(readlink "$OUTPUT_DIR/result-initrd")"
                      echo "  $OUTPUT_DIR/result-system -> $(readlink "$OUTPUT_DIR/result-system")"
                      echo "  $OUTPUT_DIR/result-guest-artifacts -> $(readlink "$OUTPUT_DIR/result-guest-artifacts")"
        ''}/bin/build-guest-artifacts";
        meta.description = "Build the NixOS guest kernel, initrd, system closure, and artifact bundle";
      };
    in
    {
      # Swift CLI package
      packages.${system} = {
        default = darwinVzNix;
        darwin-vz-nix = darwinVzNix;
        zstd = pkgs.zstd;
      };

      nixosModules.default = ./nix/guest;

      lib.${linuxSystem}.mkGuestConfiguration =
        {
          modules ? [ ],
          specialArgs ? { },
        }:
        nixpkgs-linux.lib.nixosSystem {
          system = linuxSystem;
          inherit specialArgs;
          modules = [ self.nixosModules.default ] ++ modules;
        };

      # NixOS guest configuration
      nixosConfigurations.darwin-vz-guest = self.lib.${linuxSystem}.mkGuestConfiguration { };

      # Guest artifacts (kernel + initrd) as packages
      packages.${linuxSystem} = {
        guest-kernel = self.nixosConfigurations.darwin-vz-guest.config.system.build.kernel;
        guest-initrd = self.nixosConfigurations.darwin-vz-guest.config.system.build.initialRamdisk;
        guest-system = self.nixosConfigurations.darwin-vz-guest.config.system.build.toplevel;
        zstd = linuxPkgs.zstd;
        guest-artifacts = linuxPkgs.runCommand "darwin-vz-nix-guest-artifacts" { } ''
          test -f ${self.packages.${linuxSystem}.guest-kernel}/Image
          test -f ${self.packages.${linuxSystem}.guest-initrd}/initrd
          test -x ${self.packages.${linuxSystem}.guest-system}/init

          mkdir -p $out
          ln -s ${self.packages.${linuxSystem}.guest-kernel}/Image $out/Image
          ln -s ${self.packages.${linuxSystem}.guest-initrd}/initrd $out/initrd
          ln -s ${self.packages.${linuxSystem}.guest-system} $out/system
        '';
      };

      apps.${linuxSystem}.build-guest-artifacts = buildGuestArtifactsApp linuxPkgs;

      # nix-darwin module
      darwinModules.default = {
        imports = [ ./nix/host/darwin-module.nix ];
        config.services.darwin-vz = {
          package = lib.mkDefault darwinVzNix;
          kernelPath = lib.mkDefault "${self.packages.${linuxSystem}.guest-kernel}/Image";
          initrdPath = lib.mkDefault "${self.packages.${linuxSystem}.guest-initrd}/initrd";
          systemPath = lib.mkDefault "${self.packages.${linuxSystem}.guest-system}";
        };
      };

      # Checks (built by `nix flake check` on aarch64-linux CI)
      checks.${linuxSystem} = {
        guest-kernel = self.packages.${linuxSystem}.guest-kernel;
        guest-initrd = self.packages.${linuxSystem}.guest-initrd;
        guest-system = self.packages.${linuxSystem}.guest-system;
        guest-artifacts = self.packages.${linuxSystem}.guest-artifacts;
        build-guest-artifacts-script =
          linuxPkgs.runCommand "check-linux-build-guest-artifacts-script"
            {
              nativeBuildInputs = [
                linuxPkgs.bash
                linuxPkgs.shellcheck
              ];
            }
            ''
              script=${self.apps.${linuxSystem}.build-guest-artifacts.program}
              bash -n "$script"
              shellcheck "$script"
              grep -F "Usage: build-guest-artifacts [--out-dir DIR] [--from-closure-manifest FILE]" "$script" >/dev/null
              grep -F -- "--out-dir requires a directory" "$script" >/dev/null
              grep -F -- "--from-closure-manifest requires a file" "$script" >/dev/null
              grep -F "materialize_from_closure_manifest" "$script" >/dev/null
              grep -F 'nix-store --verify-path "$bundle"' "$script" >/dev/null
              grep -F "Unknown argument:" "$script" >/dev/null
              grep -F "DARWIN_VZ_NIX_ARTIFACT_DIR" "$script" >/dev/null
              grep -F "Host system" "$script" >/dev/null
              grep -F "FLAKE_REF=" "$script" >/dev/null
              ! grep -F '".#packages.aarch64-linux' "$script" >/dev/null
              grep -F "can_build_aarch64_linux_locally" "$script" >/dev/null
              grep -F "nix config show" "$script" >/dev/null
              grep -F -- "--accept-flake-config" "$script" >/dev/null
              grep -F "builders-use-substitutes" "$script" >/dev/null
              ! grep -F -- "extra-platforms aarch64-linux" "$script" >/dev/null
              grep -F "build_artifact guest-artifacts guest-artifacts result-guest-artifacts Image initrd system/init" "$script" >/dev/null
              grep -F "validate_guest_artifact_links" "$script" >/dev/null
              grep -F 'require_regular_file "$OUTPUT_DIR/result-guest-artifacts/Image"' "$script" >/dev/null
              grep -F 'require_regular_file "$OUTPUT_DIR/result-guest-artifacts/initrd"' "$script" >/dev/null
              grep -F 'require_executable "$OUTPUT_DIR/result-guest-artifacts/system/init"' "$script" >/dev/null
              touch $out
            '';
      };

      # Checks for aarch64-darwin
      checks.${system} = {
        darwin-vz-nix = darwinVzNix;
        darwin-module =
          let
            customGuest = self.lib.${linuxSystem}.mkGuestConfiguration {
              modules = [
                {
                  environment.etc."darwin-vz-custom-marker".text = "ok";
                  nix.settings.allowed-users = [ "builder" ];
                }
              ];
            };
            testSystem = nix-darwin.lib.darwinSystem {
              inherit system;
              modules = [
                self.darwinModules.default
                {
                  services.darwin-vz = {
                    enable = true;
                    workingDirectory = "/var/lib/darwin-vz-nix";
                    rosetta = true;
                    verbose = true;
                  };
                }
              ];
            };
            escapedPathSystem = nix-darwin.lib.darwinSystem {
              inherit system;
              modules = [
                self.darwinModules.default
                {
                  services.darwin-vz = {
                    enable = true;
                    workingDirectory = "/var/lib/darwin vz-nix";
                  };
                }
              ];
            };
            evaluatedConfig = builtins.toFile "darwin-module-evaluated.json" (
              builtins.toJSON {
                buildMachineCount = builtins.length testSystem.config.nix.buildMachines;
                buildMachine = builtins.head testSystem.config.nix.buildMachines;
                buildersUseSubstitutes = testSystem.config.nix.settings.builders-use-substitutes;
                distributedBuilds = testSystem.config.nix.distributedBuilds;
                launchdArgumentCount = builtins.length testSystem.config.launchd.daemons.darwin-vz-nix.serviceConfig.ProgramArguments;
                launchdWorkingDirectory =
                  testSystem.config.launchd.daemons.darwin-vz-nix.serviceConfig.WorkingDirectory;
                launchdStdout = testSystem.config.launchd.daemons.darwin-vz-nix.serviceConfig.StandardOutPath;
                newsyslogConfig = testSystem.config.environment.etc."newsyslog.d/darwin-vz-nix.conf".text;
                escapedPathHasNewsyslog =
                  escapedPathSystem.config.environment.etc ? "newsyslog.d/darwin-vz-nix.conf";
                kernelPath = builtins.unsafeDiscardStringContext testSystem.config.services.darwin-vz.kernelPath;
                initrdPath = builtins.unsafeDiscardStringContext testSystem.config.services.darwin-vz.initrdPath;
                systemPath = builtins.unsafeDiscardStringContext testSystem.config.services.darwin-vz.systemPath;
                sshConfig = testSystem.config.environment.etc."ssh/ssh_config.d/200-darwin-vz-nix.conf".text;
                escapedSshConfig =
                  escapedPathSystem.config.environment.etc."ssh/ssh_config.d/200-darwin-vz-nix.conf".text;
                activationScript = testSystem.config.system.activationScripts.postActivation.text;
                # nix-darwin only stitches a fixed, hardcoded set of activationScripts
                # names into system.activationScripts.script.text (the script it
                # actually runs); types.attrsOf (types.submodule ...) accepts any other
                # attribute name without error, but silently never invokes it. Check
                # the fully-wired script directly, not just the intermediate attribute
                # our module happens to write to, so picking an unwired name again
                # fails this check instead of silently doing nothing at runtime.
                wiredActivationScript = builtins.unsafeDiscardStringContext testSystem.config.system.activationScripts.script.text;
                customGuestHostName = customGuest.config.networking.hostName;
                customGuestMarker = customGuest.config.environment.etc."darwin-vz-custom-marker".text;
                customGuestAllowedUsers = customGuest.config.nix.settings.allowed-users;
                initrdPrepareNixVarScript = customGuest.config.boot.initrd.systemd.services.prepare-nix-var.script;
              }
            );
          in
          pkgs.runCommand "check-darwin-module" { nativeBuildInputs = [ pkgs.jq ]; } ''
            config_json=${evaluatedConfig}

            jq -e '.buildMachineCount == 1' "$config_json" >/dev/null
            jq -e '.buildMachine.hostName == "darwin-vz-nix"' "$config_json" >/dev/null
            jq -e '.buildMachine.sshUser == "builder"' "$config_json" >/dev/null
            jq -e '.buildMachine.systems == ["aarch64-linux", "x86_64-linux"]' "$config_json" >/dev/null
            jq -e '.buildersUseSubstitutes == true' "$config_json" >/dev/null
            jq -e '.distributedBuilds == true' "$config_json" >/dev/null
            jq -e '.launchdArgumentCount == 1' "$config_json" >/dev/null
            jq -e '.launchdWorkingDirectory == "/var/lib/darwin-vz-nix"' "$config_json" >/dev/null
            jq -e '.launchdStdout == "/var/lib/darwin-vz-nix/daemon.log"' "$config_json" >/dev/null
            jq -e '.newsyslogConfig | contains("/var/lib/darwin-vz-nix/daemon.log")' "$config_json" >/dev/null
            jq -e '.newsyslogConfig | contains("/var/lib/darwin-vz-nix/console.log")' "$config_json" >/dev/null
            jq -e '.escapedPathHasNewsyslog == false' "$config_json" >/dev/null
            jq -e '.kernelPath | endswith("/Image")' "$config_json" >/dev/null
            jq -e '.initrdPath | endswith("/initrd")' "$config_json" >/dev/null
            jq -e '.systemPath | test("/nix/store/.*nixos-system-darwin-vz-guest")' "$config_json" >/dev/null
            jq -e '.sshConfig | contains("Host darwin-vz-nix")' "$config_json" >/dev/null
            jq -e '.sshConfig | contains("ProxyCommand /bin/sh")' "$config_json" >/dev/null
            jq -e '.sshConfig | contains("cat -- \"$1\"")' "$config_json" >/dev/null
            jq -e '.sshConfig | contains(" sh /var/lib/darwin-vz-nix/guest-ip")' "$config_json" >/dev/null
            jq -e --arg expected "sh '/var/lib/darwin vz-nix/guest-ip'" '.escapedSshConfig | contains($expected)' "$config_json" >/dev/null
            jq -e '.activationScript | contains("ssh-keygen -y -f")' "$config_json" >/dev/null
            jq -e '.activationScript | contains("id_ed25519.pub.tmp")' "$config_json" >/dev/null
            jq -e '.activationScript | contains("chmod 600 \"$SSH_WORK_DIR/id_ed25519\"")' "$config_json" >/dev/null
            jq -e '.wiredActivationScript | contains("id_ed25519.pub.tmp")' "$config_json" >/dev/null
            jq -e '.customGuestHostName == "darwin-vz-guest"' "$config_json" >/dev/null
            jq -e '.customGuestMarker == "ok"' "$config_json" >/dev/null
            jq -e '.customGuestAllowedUsers == ["builder"]' "$config_json" >/dev/null
            jq -e '.initrdPrepareNixVarScript | contains("/sysroot/nix/.rw-store/store")' "$config_json" >/dev/null
            jq -e '.initrdPrepareNixVarScript | contains("/sysroot/nix/.rw-store/work")' "$config_json" >/dev/null

            touch $out
          '';
        build-guest-artifacts-script =
          pkgs.runCommand "check-build-guest-artifacts-script"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.shellcheck
              ];
            }
            ''
              script=${self.apps.${system}.build-guest-artifacts.program}
              bash -n "$script"
              shellcheck "$script"
              grep -F "Usage: build-guest-artifacts [--out-dir DIR] [--from-closure-manifest FILE]" "$script" >/dev/null
              grep -F -- "--out-dir requires a directory" "$script" >/dev/null
              grep -F -- "--from-closure-manifest requires a file" "$script" >/dev/null
              grep -F "materialize_from_closure_manifest" "$script" >/dev/null
              grep -F "Materializing guest artifacts from closure manifest" "$script" >/dev/null
              grep -F 'nix-store --verify-path "$bundle"' "$script" >/dev/null
              grep -F "Unknown argument:" "$script" >/dev/null
              grep -F "DARWIN_VZ_NIX_ARTIFACT_DIR" "$script" >/dev/null
              grep -F "aarch64-linux guest artifacts" "$script" >/dev/null
              grep -F "Configured builders" "$script" >/dev/null
              grep -F "Host system" "$script" >/dev/null
              grep -F "FLAKE_REF=" "$script" >/dev/null
              ! grep -F '".#packages.aarch64-linux' "$script" >/dev/null
              grep -F "can_build_aarch64_linux_locally" "$script" >/dev/null
              grep -F "nix config show" "$script" >/dev/null
              grep -F -- "--accept-flake-config" "$script" >/dev/null
              grep -F "builders-use-substitutes" "$script" >/dev/null
              ! grep -F -- "extra-platforms aarch64-linux" "$script" >/dev/null
              grep -F "No usable aarch64-linux builder was found" "$script" >/dev/null
              grep -F "Preflighting bundled guest artifacts against configured substituters" "$script" >/dev/null
              grep -F "No partial result links were written" "$script" >/dev/null
              grep -F "NO_USABLE_AARCH64_LINUX_BUILDER=1" "$script" >/dev/null
              grep -F "link_bundled_artifacts" "$script" >/dev/null
              grep -F 'replace_link "$OUTPUT_DIR/result-kernel" "$bundle"' "$script" >/dev/null
              grep -F 'replace_link "$OUTPUT_DIR/result-initrd" "$bundle"' "$script" >/dev/null
              grep -F 'replace_link "$OUTPUT_DIR/result-system" "$bundle/system"' "$script" >/dev/null
              grep -F 'require_regular_file "$OUTPUT_DIR/result-kernel/Image"' "$script" >/dev/null
              grep -F 'require_regular_file "$OUTPUT_DIR/result-initrd/initrd"' "$script" >/dev/null
              grep -F 'require_executable "$OUTPUT_DIR/result-system/init"' "$script" >/dev/null
              grep -F 'require_regular_file "$OUTPUT_DIR/result-guest-artifacts/Image"' "$script" >/dev/null
              grep -F 'require_regular_file "$OUTPUT_DIR/result-guest-artifacts/initrd"' "$script" >/dev/null
              grep -F 'require_executable "$OUTPUT_DIR/result-guest-artifacts/system/init"' "$script" >/dev/null
              grep -F "validate_guest_artifact_links" "$script" >/dev/null
              ! grep -F -- "--max-jobs 0" "$script" >/dev/null
              grep -F "build_artifact guest-kernel guest-kernel result-kernel Image" "$script" >/dev/null
              grep -F "build_artifact guest-initrd guest-initrd result-initrd initrd" "$script" >/dev/null
              grep -F "build_artifact guest-system guest-system result-system init" "$script" >/dev/null
              grep -F "build_artifact guest-artifacts guest-artifacts result-guest-artifacts Image initrd system/init" "$script" >/dev/null
              grep -F "result-guest-artifacts" "$script" >/dev/null
              touch $out
            '';
        smoke-test-script =
          pkgs.runCommand "check-smoke-test-script"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.shellcheck
              ];
            }
            ''
              script=${self.apps.${system}.smoke-test.program}
              bash -n "$script"
              shellcheck "$script"
              grep -F "Starting darwin-vz-nix VM smoke test" "$script" >/dev/null
              grep -F "build-guest-artifacts" "$script" >/dev/null
              grep -F "darwin-vz-nix\" start" "$script" >/dev/null
              grep -F "darwin-vz-nix\" ssh" "$script" >/dev/null
              grep -F "darwin-vz-nix\" stop" "$script" >/dev/null
              grep -F "Smoke test passed" "$script" >/dev/null
              grep -F "STATE_DIR_OWNED=1" "$script" >/dev/null
              grep -F "DARWIN_VZ_NIX_SMOKE_TMPDIR" "$script" >/dev/null
              grep -F "DARWIN_VZ_NIX_SMOKE_BUILD_ARTIFACTS" "$script" >/dev/null
              grep -F "artifact_links_ready" "$script" >/dev/null
              grep -F 'test -x "$OUTPUT_DIR/result-guest-artifacts/system/init"' "$script" >/dev/null
              grep -F 'test -x "$BUNDLE/system/init"' "$script" >/dev/null
              grep -F "Using existing guest artifact links" "$script" >/dev/null
              grep -F "STATE_DIR_PREFIX" "$script" >/dev/null
              grep -F "Refusing to remove unexpected smoke state dir" "$script" >/dev/null
              grep -F "must be a positive integer" "$script" >/dev/null
              grep -F "require_disk_size" "$script" >/dev/null
              grep -F "DARWIN_VZ_NIX_SMOKE_DISK_SIZE must be a positive size" "$script" >/dev/null
              touch $out
            '';
        github-actions =
          pkgs.runCommand "check-github-actions" { nativeBuildInputs = [ pkgs.actionlint ]; }
            ''
              cd ${./.}
              actionlint -color=false .github/workflows/*.yml
              grep -F "nix shell .#zstd -c zstd" .github/workflows/ci.yml >/dev/null
              grep -F "nix shell .#zstd -c zstd" .github/workflows/release.yml >/dev/null
              grep -F "VM Smoke Test Notice" .github/workflows/ci.yml >/dev/null
              grep -F "runs-on: [self-hosted, macOS, ARM64]" .github/workflows/vm-smoke.yml >/dev/null
              grep -F "nix-store --import" .github/workflows/vm-smoke.yml >/dev/null
              grep -F "nix-store --verify-path" .github/workflows/vm-smoke.yml >/dev/null
              grep -F "name: Materialize guest artifact links" .github/workflows/vm-smoke.yml >/dev/null
              grep -F -- "--from-closure-manifest ci-artifacts/guest-artifacts.closure" .github/workflows/vm-smoke.yml >/dev/null
              grep -F "ci-artifacts/runtime/result-guest-artifacts" .github/workflows/ci.yml >/dev/null
              grep -F "ci-artifacts/runtime/result-guest-artifacts" .github/workflows/release.yml >/dev/null
              grep -F "ci-artifacts/runtime/result-guest-artifacts" .github/workflows/vm-smoke.yml >/dev/null
              grep -F "ci-artifacts/guest-artifacts.closure" .github/workflows/ci.yml >/dev/null
              grep -F "ci-artifacts/guest-artifacts.nar.zst" .github/workflows/ci.yml >/dev/null
              grep -F "test -s ci-artifacts/guest-artifacts.closure" .github/workflows/ci.yml >/dev/null
              grep -F "test -s ci-artifacts/guest-artifacts.nar.zst" .github/workflows/ci.yml >/dev/null
              grep -F "ci-artifacts/guest-artifacts.closure" .github/workflows/release.yml >/dev/null
              grep -F "ci-artifacts/guest-artifacts.nar.zst" .github/workflows/release.yml >/dev/null
              grep -F "test -s ci-artifacts/guest-artifacts.closure" .github/workflows/release.yml >/dev/null
              grep -F "test -s ci-artifacts/guest-artifacts.nar.zst" .github/workflows/release.yml >/dev/null
              grep -F "ci-artifacts/guest-artifacts.closure" .github/workflows/vm-smoke.yml >/dev/null
              grep -F "ci-artifacts/guest-artifacts.nar.zst" .github/workflows/vm-smoke.yml >/dev/null
              grep -F "test -s ci-artifacts/guest-artifacts.closure" .github/workflows/vm-smoke.yml >/dev/null
              grep -F "test -s ci-artifacts/guest-artifacts.nar.zst" .github/workflows/vm-smoke.yml >/dev/null
              grep -F "Unexpected non-store path in guest artifact closure manifest" .github/workflows/vm-smoke.yml >/dev/null
              grep -F "Empty path in guest artifact closure manifest" .github/workflows/vm-smoke.yml >/dev/null
              grep -F "nix run .#build-guest-artifacts -- --out-dir ci-artifacts/runtime" .github/workflows/ci.yml >/dev/null
              grep -F "nix run .#build-guest-artifacts -- --out-dir ci-artifacts/runtime" .github/workflows/release.yml >/dev/null
              grep -F "nix run .#build-guest-artifacts -- --out-dir ci-artifacts/runtime" .github/workflows/vm-smoke.yml >/dev/null
              grep -F 'DARWIN_VZ_NIX_ARTIFACT_DIR: ''${{ github.workspace }}/ci-artifacts/runtime' .github/workflows/vm-smoke.yml >/dev/null
              grep -F 'DARWIN_VZ_NIX_SMOKE_STATE_DIR: ''${{ github.workspace }}/ci-artifacts/smoke-state' .github/workflows/vm-smoke.yml >/dev/null
              grep -F 'DARWIN_VZ_NIX_SMOKE_KEEP_STATE: "1"' .github/workflows/vm-smoke.yml >/dev/null
              grep -F "DARWIN_VZ_NIX_SMOKE_BUILD_ARTIFACTS: never" .github/workflows/vm-smoke.yml >/dev/null
              grep -F "Upload VM smoke logs" .github/workflows/vm-smoke.yml >/dev/null
              grep -F "vm-smoke-logs" .github/workflows/vm-smoke.yml >/dev/null
              grep -F "nix run .#build-guest-artifacts" .github/workflows/vm-smoke.yml >/dev/null
              grep -F "nix run .#smoke-test" .github/workflows/vm-smoke.yml >/dev/null
              grep -F "nix run .#smoke-test" .github/workflows/release.yml >/dev/null
              grep -F "ENABLE_VM_SMOKE_GATE" .github/workflows/release.yml >/dev/null
              grep -F "needs.smoke-gate.result == 'skipped'" .github/workflows/release.yml >/dev/null
              # The release smoke-gate duplicates vm-smoke.yml's smoke step; guard
              # the env block against drift between the two files.
              grep -F 'DARWIN_VZ_NIX_ARTIFACT_DIR: ''${{ github.workspace }}/ci-artifacts/runtime' .github/workflows/release.yml >/dev/null
              grep -F 'DARWIN_VZ_NIX_SMOKE_STATE_DIR: ''${{ github.workspace }}/ci-artifacts/smoke-state' .github/workflows/release.yml >/dev/null
              grep -F 'DARWIN_VZ_NIX_SMOKE_KEEP_STATE: "1"' .github/workflows/release.yml >/dev/null
              grep -F "DARWIN_VZ_NIX_SMOKE_BUILD_ARTIFACTS: never" .github/workflows/release.yml >/dev/null
              grep -E "if: inputs[.]cachix-auth-token == [']{2}$" .github/actions/setup-nix/action.yml >/dev/null
              grep -E "if: inputs[.]cachix-auth-token != [']{2}$" .github/actions/setup-nix/action.yml >/dev/null
              grep -F "Verify release tag matches package version" .github/workflows/release.yml >/dev/null
              grep -F "nix eval --raw .#packages.aarch64-darwin.darwin-vz-nix.version" .github/workflows/release.yml >/dev/null
              grep -F 'expected_tag="v''${package_version}"' .github/workflows/release.yml >/dev/null
              grep -F "dist/darwin-vz-nix-aarch64-darwin" .github/workflows/release.yml >/dev/null
              grep -F "shasum -a 256 darwin-vz-nix-aarch64-darwin" .github/workflows/release.yml >/dev/null
              touch $out
            '';
        swift-dependencies =
          pkgs.runCommand "check-swift-dependencies"
            {
              nativeBuildInputs = [
                pkgs.gnugrep
                pkgs.jq
              ];
            }
            ''
              cd ${./.}
              ! grep -R -E "github.com/apple/swift-testing|github.com/apple/swift-syntax|swift-testing-src|swift-syntax-src" \
                Package.swift Package.resolved nix/package.nix >/dev/null
              grep -F "swift-argument-parser" Package.swift >/dev/null
              jq -e '.pins | length == 1' Package.resolved >/dev/null
              jq -e '.pins[0].identity == "swift-argument-parser"' Package.resolved >/dev/null
              jq -e '.pins[0].state.revision | length > 0' Package.resolved >/dev/null
              jq -e '.pins[0].state.version | test("^1[.]5[.]")' Package.resolved >/dev/null
              grep -F "builtins.fromJSON (builtins.readFile ../Package.resolved)" nix/package.nix >/dev/null
              grep -F "swiftArgumentParserPin.state.revision" nix/package.nix >/dev/null
              grep -F "swiftArgumentParserPin.state.version" nix/package.nix >/dev/null
              grep -F "swift-argument-parser-src" nix/package.nix >/dev/null
              touch $out
            '';
        # The committed Version.swift, the package version (from VERSION), and the
        # built binary's --version must all agree. VERSION is the single source.
        version-consistency = pkgs.runCommand "check-version-consistency" { } ''
          grep -F '"${darwinVzNix.version}"' ${./Sources/DarwinVZNixLib/Version.swift} >/dev/null \
            || { echo "Version.swift must contain ${darwinVzNix.version} (from VERSION)" >&2; exit 1; }
          got=$(${darwinVzNix}/bin/darwin-vz-nix --version)
          [ "$got" = "${darwinVzNix.version}" ] \
            || { echo "binary --version ($got) != ${darwinVzNix.version}" >&2; exit 1; }
          touch $out
        '';
        # Guard against the AppleDouble regression: the toolchain used to build
        # and test MUST be free of ._* resource-fork files, or `swift test` breaks.
        swift-toolchain-clean = pkgs.runCommand "check-swift-toolchain-clean" { } ''
          count=$(find ${swiftBin} -name '._*' -type f | wc -l | tr -d ' ')
          if [ "$count" -ne 0 ]; then
            echo "swiftBin still contains $count AppleDouble (._*) files; swift test will break." >&2
            exit 1
          fi
          touch $out
        '';
        swift-test = darwinVzNix.overrideAttrs (_: {
          name = "darwin-vz-nix-test";
          buildPhase = ''
            runHook preBuild

            mkdir -p .swiftpm-cache .home
            export HOME=$PWD/.home
            unset CPLUS_INCLUDE_PATH NIX_CC NIX_LDFLAGS NIX_CFLAGS_COMPILE CC CXX DEVELOPER_DIR
            export SDKROOT=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
            export NIX_ENFORCE_PURITY=0
            swift test \
              --parallel \
              --disable-sandbox \
              --disable-xctest \
              --disable-automatic-resolution \
              --disable-dependency-cache \
              --cache-path "$PWD/.swiftpm-cache" \
              --scratch-path "$PWD/.build"

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
                !(
                  baseName == ".git"
                  || baseName == ".build"
                  || baseName == ".swiftpm"
                  || baseName == ".swiftpm-cache"
                  || baseName == ".home"
                  || lib.hasPrefix "result" baseName
                );
            };
          in
          pkgs.runCommand "check-formatting" { } ''
            export HOME=$TMPDIR
            find ${src} -name '*.nix' -exec ${pkgs.nixfmt}/bin/nixfmt --check {} +
            ${pkgs.swiftformat}/bin/swiftformat --swiftversion 6.0 --cache ignore --lint ${src}/Sources ${src}/Tests
            touch $out
          '';
      };

      apps.${system} = {
        default = self.apps.${system}.darwin-vz-nix;
        darwin-vz-nix = {
          type = "app";
          program = "${darwinVzNix}/bin/darwin-vz-nix";
          meta.description = "Manage NixOS Linux VMs using macOS Virtualization.framework";
        };
        # Convenience app to build all guest artifacts at once
        build-guest-artifacts = buildGuestArtifactsApp pkgs;
        smoke-test = {
          type = "app";
          program = "${pkgs.writeShellScriptBin "darwin-vz-nix-smoke-test" ''
            set -euo pipefail

            OUTPUT_DIR=''${DARWIN_VZ_NIX_ARTIFACT_DIR:-$PWD}
            OUTPUT_DIR=$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)
            STATE_DIR=''${DARWIN_VZ_NIX_SMOKE_STATE_DIR:-}
            TMP_BASE=''${DARWIN_VZ_NIX_SMOKE_TMPDIR:-''${TMPDIR:-/tmp}}
            TMP_BASE=$(mkdir -p "$TMP_BASE" && cd "$TMP_BASE" && pwd)
            TMP_BASE=''${TMP_BASE%/}
            STATE_DIR_PREFIX="$TMP_BASE/darwin-vz-nix-smoke."
            SMOKE_TIMEOUT=''${DARWIN_VZ_NIX_SMOKE_TIMEOUT:-180}
            SMOKE_MEMORY=''${DARWIN_VZ_NIX_SMOKE_MEMORY:-2048}
            SMOKE_DISK_SIZE=''${DARWIN_VZ_NIX_SMOKE_DISK_SIZE:-20G}
            KEEP_STATE=''${DARWIN_VZ_NIX_SMOKE_KEEP_STATE:-0}
            ARTIFACT_MODE=''${DARWIN_VZ_NIX_SMOKE_BUILD_ARTIFACTS:-auto}

            require_positive_integer() {
              name="$1"
              value="$2"
              case "$value" in
                "" | *[!0-9]*)
                  echo "$name must be a positive integer, got: $value" >&2
                  exit 2
                  ;;
              esac
              case "$value" in
                *[1-9]*) ;;
                *)
                  echo "$name must be a positive integer, got: $value" >&2
                  exit 2
                  ;;
              esac
            }

            require_disk_size() {
              value="$1"
              case "$value" in
                "" | *[!0-9kKmMgGtT]*)
                  echo "DARWIN_VZ_NIX_SMOKE_DISK_SIZE must be a positive size like 20G, 512M, or bytes, got: $value" >&2
                  exit 2
                  ;;
                *[kKmMgGtT])
                  number=''${value%?}
                  case "$number" in
                    "" | *[!0-9]*)
                      echo "DARWIN_VZ_NIX_SMOKE_DISK_SIZE must be a positive size like 20G, 512M, or bytes, got: $value" >&2
                      exit 2
                      ;;
                  esac
                  case "$number" in
                    *[1-9]*) ;;
                    *)
                      echo "DARWIN_VZ_NIX_SMOKE_DISK_SIZE must be a positive size like 20G, 512M, or bytes, got: $value" >&2
                      exit 2
                      ;;
                  esac
                  ;;
                *)
                  case "$value" in
                    *[1-9]*) ;;
                    *)
                      echo "DARWIN_VZ_NIX_SMOKE_DISK_SIZE must be a positive size like 20G, 512M, or bytes, got: $value" >&2
                      exit 2
                      ;;
                  esac
                  ;;
              esac
            }

            require_positive_integer DARWIN_VZ_NIX_SMOKE_TIMEOUT "$SMOKE_TIMEOUT"
            require_positive_integer DARWIN_VZ_NIX_SMOKE_MEMORY "$SMOKE_MEMORY"
            require_disk_size "$SMOKE_DISK_SIZE"

            case "$ARTIFACT_MODE" in
              auto | always | never) ;;
              *)
                echo "DARWIN_VZ_NIX_SMOKE_BUILD_ARTIFACTS must be auto, always, or never, got: $ARTIFACT_MODE" >&2
                exit 2
                ;;
            esac

            artifact_links_ready() {
              test -f "$OUTPUT_DIR/result-kernel/Image" &&
                test -f "$OUTPUT_DIR/result-initrd/initrd" &&
                test -x "$OUTPUT_DIR/result-system/init" &&
                test -f "$OUTPUT_DIR/result-guest-artifacts/Image" &&
                test -f "$OUTPUT_DIR/result-guest-artifacts/initrd" &&
                test -x "$OUTPUT_DIR/result-guest-artifacts/system/init"
            }

            build_guest_artifacts() {
              DARWIN_VZ_NIX_ARTIFACT_DIR="$OUTPUT_DIR" ${self.apps.${system}.build-guest-artifacts.program}
            }

            STATE_DIR_OWNED=0
            if [ -z "$STATE_DIR" ]; then
              STATE_DIR=$(mktemp -d "$STATE_DIR_PREFIX"XXXXXX)
              STATE_DIR_OWNED=1
            else
              mkdir -p "$STATE_DIR"
              STATE_DIR=$(cd "$STATE_DIR" && pwd)
            fi

            start_pid=""

            # shellcheck disable=SC2329
            cleanup() {
              if [ -n "''${start_pid:-}" ] && kill -0 "$start_pid" 2>/dev/null; then
                "${darwinVzNix}/bin/darwin-vz-nix" stop --state-dir "$STATE_DIR" --force >/dev/null 2>&1 || true
                wait "$start_pid" 2>/dev/null || true
              fi

              if [ "$STATE_DIR_OWNED" -eq 1 ] && [ "$KEEP_STATE" != "1" ]; then
                case "$STATE_DIR" in
                  "$STATE_DIR_PREFIX"*)
                    rm -rf "$STATE_DIR"
                    ;;
                  *)
                    echo "Refusing to remove unexpected smoke state dir: $STATE_DIR" >&2
                    ;;
                esac
              else
                echo "State directory: $STATE_DIR"
              fi
            }
            trap cleanup EXIT INT TERM

            echo "Starting darwin-vz-nix VM smoke test"
            echo "Artifact directory: $OUTPUT_DIR"
            echo "State directory: $STATE_DIR"

            case "$ARTIFACT_MODE" in
              always)
                build_guest_artifacts
                ;;
              never)
                if ! artifact_links_ready; then
                  echo "Guest artifact links are missing in $OUTPUT_DIR and DARWIN_VZ_NIX_SMOKE_BUILD_ARTIFACTS=never." >&2
                  echo "Run nix run .#build-guest-artifacts -- --out-dir \"$OUTPUT_DIR\" first, or set DARWIN_VZ_NIX_SMOKE_BUILD_ARTIFACTS=auto." >&2
                  exit 1
                fi
                echo "Using existing guest artifact links in $OUTPUT_DIR"
                ;;
              auto)
                if artifact_links_ready; then
                  echo "Using existing guest artifact links in $OUTPUT_DIR"
                else
                  build_guest_artifacts
                fi
                ;;
            esac

            KERNEL="$OUTPUT_DIR/result-kernel/Image"
            INITRD="$OUTPUT_DIR/result-initrd/initrd"
            SYSTEM="$OUTPUT_DIR/result-system"
            BUNDLE="$OUTPUT_DIR/result-guest-artifacts"
            LOG="$STATE_DIR/smoke-start.log"

            test -f "$KERNEL"
            test -f "$INITRD"
            test -x "$SYSTEM/init"
            test -f "$BUNDLE/Image"
            test -f "$BUNDLE/initrd"
            test -x "$BUNDLE/system/init"

            "${darwinVzNix}/bin/darwin-vz-nix" start \
              --kernel "$KERNEL" \
              --initrd "$INITRD" \
              --system "$SYSTEM" \
              --state-dir "$STATE_DIR" \
              --memory "$SMOKE_MEMORY" \
              --disk-size "$SMOKE_DISK_SIZE" \
              >"$LOG" 2>&1 &
            start_pid=$!

            deadline=$(( $(date +%s) + SMOKE_TIMEOUT ))
            while [ "$(date +%s)" -lt "$deadline" ]; do
              if ! kill -0 "$start_pid" 2>/dev/null; then
                status=0
                wait "$start_pid" || status=$?
                echo "VM process exited before SSH became ready (exit $status)." >&2
                tail -n 80 "$LOG" >&2 || true
                exit 1
              fi

              if [ -s "$STATE_DIR/guest-ip" ]; then
                if "${darwinVzNix}/bin/darwin-vz-nix" ssh --state-dir "$STATE_DIR" -- true; then
                  echo "Smoke test passed: VM booted, SSH accepted a command, and shutdown was requested."
                  "${darwinVzNix}/bin/darwin-vz-nix" stop --state-dir "$STATE_DIR" --force
                  wait "$start_pid" || true
                  start_pid=""
                  exit 0
                fi
              fi

              sleep 2
            done

            echo "Timed out waiting for the VM to accept SSH after ''${SMOKE_TIMEOUT}s." >&2
            echo "Last VM log lines:" >&2
            tail -n 120 "$LOG" >&2 || true
            "${darwinVzNix}/bin/darwin-vz-nix" doctor || true
            exit 1
          ''}/bin/darwin-vz-nix-smoke-test";
          meta.description = "Build guest artifacts, boot the VM, verify SSH, and stop it";
        };
      };

      # Formatter
      formatter.${system} = pkgs.nixfmt-tree;

      # Dev shell for Swift development
      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs = [
          swiftBin
          (pkgs.writeShellScriptBin "swift-test-fast" ''
            set -euo pipefail

            mkdir -p .swiftpm-cache .home
            export HOME="$PWD/.home"
            unset CPLUS_INCLUDE_PATH NIX_CC NIX_LDFLAGS NIX_CFLAGS_COMPILE CC CXX DEVELOPER_DIR
            export SDKROOT=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
            export NIX_ENFORCE_PURITY=0

            exec swift test \
              --parallel \
              --disable-sandbox \
              --disable-xctest \
              --disable-automatic-resolution \
              --disable-dependency-cache \
              --cache-path "$PWD/.swiftpm-cache" \
              --scratch-path "$PWD/.build" \
              "$@"
          '')
          pkgs.swiftformat
          pkgs.swiftlint
          pkgs.nixfmt
        ];
        shellHook = ''
          echo "darwin-vz-nix development shell"
          echo "  swift: $(swift --version 2>&1 | head -1)"
          echo "  swiftformat: $(swiftformat --version)"
          echo ""
          echo "Commands:"
          echo "  swift build                Build Swift project"
          echo "  swift-test-fast            Run Swift tests with the CI SDK/cache settings"
          echo "  nix build                  Build darwin-vz-nix package"
          echo "  nix flake check            Run all checks (tests + formatting)"
          echo "  nix fmt                    Format Nix files"
          echo "  nix run .#smoke-test       Build artifacts, boot VM, verify SSH, and stop"
          echo ""
          echo "Quick start (run a NixOS VM):"
          echo "  nix run .#build-guest-artifacts"
          echo "  nix run .#smoke-test"
          echo "  nix run .#darwin-vz-nix -- start --kernel ./result-kernel/Image --initrd ./result-initrd/initrd --system ./result-system"
          echo "  nix run .#darwin-vz-nix -- ssh"
          echo "  nix run .#darwin-vz-nix -- stop"
          echo "  nix run .#darwin-vz-nix -- destroy"
        '';
      };
    };
}
