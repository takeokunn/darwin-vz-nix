{
  lib,
  stdenv,
  darwin,
  apple-sdk_14,
  swift-bin,
  swift-argument-parser-src,
}:

let
  swiftFiles =
    path: lib.fileset.fileFilter (file: file.type == "regular" && file.hasExt "swift") path;
  packageResolved = builtins.fromJSON (builtins.readFile ../Package.resolved);
  swiftArgumentParserPin = lib.findFirst (
    pin: pin.identity == "swift-argument-parser"
  ) (throw "Package.resolved does not pin swift-argument-parser") packageResolved.pins;
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
                revision = swiftArgumentParserPin.state.revision;
                version = swiftArgumentParserPin.state.version;
              };
              name = "sourceControlCheckout";
            };
            subpath = "swift-argument-parser";
          }
        ];
      };
    }
  );
in

stdenv.mkDerivation (finalAttrs: {
  pname = "darwin-vz-nix";
  # Single source of truth: the repository VERSION file. The CLI's --version,
  # the package version, and the release tag all derive from it.
  version = lib.removeSuffix "\n" (builtins.readFile ../VERSION);

  src = lib.fileset.toSource {
    root = ./..;
    fileset = lib.fileset.unions [
      ../Package.swift
      ../Package.resolved
      ../VERSION
      (swiftFiles ../Sources)
      (swiftFiles ../Tests)
    ];
  };

  nativeBuildInputs = [
    apple-sdk_14
    swift-bin
    darwin.sigtool
  ];

  configurePhase = ''
    runHook preConfigure

    mkdir -p .build/checkouts .swiftpm-cache .home
    install -m 0600 ${workspaceStateFile} ./.build/workspace-state.json
    ln -s '${swift-argument-parser-src}' '.build/checkouts/swift-argument-parser'

    # Regenerate Version.swift from the single-source VERSION file so the built
    # binary's --version always matches the package/release version.
    cat > Sources/DarwinVZNixLib/Version.swift <<EOF
    public enum BuildInfo {
        public static let version = "${finalAttrs.version}"
    }
    EOF

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export HOME=$PWD/.home
    swift build \
      -c release \
      --disable-sandbox \
      --disable-automatic-resolution \
      --disable-dependency-cache \
      --cache-path "$PWD/.swiftpm-cache" \
      --scratch-path "$PWD/.build"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp .build/release/darwin-vz-nix $out/bin/

    runHook postInstall
  '';

  # Sign after fixupPhase (which runs strip) to preserve the signature.
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
    maintainers = [ ];
    mainProgram = "darwin-vz-nix";
    platforms = [ "aarch64-darwin" ];
  };
})
