/// Build/version information for the CLI.
///
/// `version` is the single source of truth surfaced by `--version` and the
/// `doctor` command. This committed value is the fallback used by a plain
/// `swift build`; the Nix package regenerates this file from the repository
/// `VERSION` file at build time so released binaries always match the tag.
/// Keep this string in sync with the repository `VERSION` file (a flake check
/// enforces it).
public enum BuildInfo {
    public static let version = "0.2.2"
}
