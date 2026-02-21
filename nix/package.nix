{
  lib,
  stdenv,
  darwin,
  swift-bin,
  swift-argument-parser-src,
  swift-testing-src,
  swift-syntax-src,
}:

let
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
                revision = "011f0c765fb46d9cac61bca19be0527e99c98c8b";
                version = "1.5.1";
              };
              name = "sourceControlCheckout";
            };
            subpath = "swift-argument-parser";
          }
          {
            basedOn = null;
            packageRef = {
              identity = "swift-testing";
              kind = "remoteSourceControl";
              location = "https://github.com/apple/swift-testing.git";
              name = "swift-testing";
            };
            state = {
              checkoutState = {
                revision = "399f76dcd91e4c688ca2301fa24a8cc6d9927211";
                version = "0.99.0";
              };
              name = "sourceControlCheckout";
            };
            subpath = "swift-testing";
          }
          {
            basedOn = null;
            packageRef = {
              identity = "swift-syntax";
              kind = "remoteSourceControl";
              location = "https://github.com/swiftlang/swift-syntax.git";
              name = "swift-syntax";
            };
            state = {
              checkoutState = {
                revision = "0687f71944021d616d34d922343dcef086855920";
                version = "600.0.1";
              };
              name = "sourceControlCheckout";
            };
            subpath = "swift-syntax";
          }
        ];
      };
    }
  );
in

stdenv.mkDerivation {
  pname = "darwin-vz-nix";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ./..;
    filter =
      path: _type:
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
    swift-bin
    darwin.sigtool
  ];

  configurePhase = ''
    runHook preConfigure

    mkdir -p .build/checkouts
    install -m 0600 ${workspaceStateFile} ./.build/workspace-state.json
    ln -s '${swift-argument-parser-src}' '.build/checkouts/swift-argument-parser'
    ln -s '${swift-testing-src}' '.build/checkouts/swift-testing'
    ln -s '${swift-syntax-src}' '.build/checkouts/swift-syntax'

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export HOME=$TMPDIR
    swift build -c release --disable-sandbox

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp .build/release/darwin-vz-nix $out/bin/

    runHook postInstall
  '';

  # Sign after fixupPhase (which runs strip) to preserve the signature
  postFixup = ''
    codesign --sign - \
      --entitlements ${../Resources/entitlements.plist} \
      --force \
      $out/bin/darwin-vz-nix
  '';

  meta = {
    description = "NixOS VM manager using macOS Virtualization.framework";
    homepage = "https://github.com/takeokunn/darwin-vz-nix";
    license = lib.licenses.mit;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "darwin-vz-nix";
  };
}
