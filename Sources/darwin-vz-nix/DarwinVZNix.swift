import ArgumentParser

@main
struct DarwinVZNix: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "darwin-vz-nix",
        abstract: "Manage NixOS Linux VMs using macOS Virtualization.framework",
        subcommands: [Start.self, Stop.self, Status.self, SSH.self]
    )
}
