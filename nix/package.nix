{
  lib,
  stdenv,
  swift,
  swiftpm,
  darwin,
  fetchgit,
}:

let
  # Pin to 1.5.0 for Swift 5.10 compatibility (nixpkgs ships Swift 5.10.1)
  # swift-argument-parser 1.6+ requires Swift 6.0 features (AccessLevelOnImport)
  swift-argument-parser = fetchgit {
    url = "https://github.com/apple/swift-argument-parser.git";
    rev = "41982a3656a71c768319979febd796c6fd111d5c"; # 1.5.0
    hash = "sha256-TRaJG8ikzuQQjH3ERfuYNKPty3qI3ziC/9v96pvlvRs=";
    fetchSubmodules = true;
  };

  # workspace-state.json for SwiftPM (version 6 for nixpkgs Swift 5.10 compatibility)
  workspaceStateFile = builtins.toFile "workspace-state.json" (
    builtins.toJSON {
      version = 6;
      object = {
        artifacts = [ ];
        dependencies = [
          {
            basedOn = null;
            packageRef = {
              identity = "swift-argument-parser";
              kind = "remoteSourceControl";
              location = "https://github.com/apple/swift-argument-parser.git";
              name = "swift-argument-parser";
            };
            state = {
              checkoutState = {
                revision = "41982a3656a71c768319979febd796c6fd111d5c";
                version = "1.5.0";
              };
              name = "sourceControlCheckout";
            };
            subpath = "swift-argument-parser";
          }
        ];
      };
    }
  );

  # Package.resolved (version 1 for SwiftPM compatibility)
  pinFile = builtins.toFile "Package.resolved" (
    builtins.toJSON {
      version = 1;
      object.pins = [
        {
          package = "swift-argument-parser";
          repositoryURL = "https://github.com/apple/swift-argument-parser.git";
          state = {
            revision = "41982a3656a71c768319979febd796c6fd111d5c";
            version = "1.5.0";
          };
        }
      ];
    }
  );
in

stdenv.mkDerivation {
  pname = "darwin-vz-nix";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ./..;
    filter =
      path: type:
      let
        baseName = builtins.baseNameOf path;
      in
      !(
        baseName == ".git"
        || baseName == ".build"
        || baseName == ".swiftpm"
        || baseName == "result"
        || lib.hasSuffix ".md" baseName
      );
  };

  nativeBuildInputs = [
    swift
    swiftpm
    darwin.sigtool
  ];

  configurePhase = ''
    runHook preConfigure

    mkdir -p .build/checkouts
    ln -sf ${pinFile} ./Package.resolved
    install -m 0600 ${workspaceStateFile} ./.build/workspace-state.json
    ln -s '${swift-argument-parser}' '.build/checkouts/swift-argument-parser'

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export HOME=$TMPDIR
    swift build -c release --disable-sandbox --skip-update

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    binPath="$(swiftpmBinPath)"
    mkdir -p $out/bin
    cp $binPath/darwin-vz-nix $out/bin/

    runHook postInstall
  '';

  # Sign after fixupPhase (which runs strip) to preserve the signature
  postFixup = ''
    codesign --sign - \
      --entitlements ${../Resources/entitlements.plist} \
      --force \
      $out/bin/darwin-vz-nix
  '';

  meta = with lib; {
    description = "NixOS VM manager using macOS Virtualization.framework";
    homepage = "https://github.com/takeokunn/darwin-vz-nix";
    license = licenses.mit;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "darwin-vz-nix";
  };
}
