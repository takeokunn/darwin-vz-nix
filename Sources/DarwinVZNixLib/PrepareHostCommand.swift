import ArgumentParser
import Foundation

public struct PrepareHost: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "prepare-host",
        abstract: "Securely prepare host state for nix-darwin activation",
        shouldDisplay: false
    )

    @Option(name: .long, help: "Absolute VM state directory")
    var stateDir: String

    @Option(name: .long, help: "Console user receiving the SSH client key")
    var consoleUser: String?

    public init() {}

    public mutating func run() throws {
        try SecureHostState.prepareHost(
            stateDirectory: URL(fileURLWithPath: stateDir),
            consoleUser: consoleUser
        )
    }
}
