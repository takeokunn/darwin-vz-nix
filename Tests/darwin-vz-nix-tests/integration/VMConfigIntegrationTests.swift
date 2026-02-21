@testable import DarwinVZNixLib
import Foundation
import Testing

@Suite("VMConfig Integration", .tags(.integration))
struct VMConfigIntegrationTests {
    @Test("ensureStateDirectory creates directory on disk")
    func ensureStateDirectoryCreatesDirectory() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let stateDir = tempDir.appendingPathComponent("state", isDirectory: true)
        let kernel = TestHelpers.createTempFile(content: "k", fileName: "kernel")
        defer { TestHelpers.removeTempItem(at: kernel) }

        let config = VMConfig(
            kernelURL: kernel, initrdURL: kernel,
            stateDirectory: stateDir
        )
        try config.ensureStateDirectory()

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: stateDir.path, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)
    }

    @Test("ensureStateDirectory sets 0o755 permissions")
    func ensureStateDirectorySetsPermissions() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let stateDir = tempDir.appendingPathComponent("state", isDirectory: true)
        let kernel = TestHelpers.createTempFile(content: "k", fileName: "kernel")
        defer { TestHelpers.removeTempItem(at: kernel) }

        let config = VMConfig(
            kernelURL: kernel, initrdURL: kernel,
            stateDirectory: stateDir
        )
        try config.ensureStateDirectory()

        let attrs = try FileManager.default.attributesOfItem(atPath: stateDir.path)
        let posix = attrs[.posixPermissions] as? Int
        #expect(posix == Int(0o755))
    }

    @Test("ensureStateDirectory is idempotent")
    func ensureStateDirectoryIdempotent() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let stateDir = tempDir.appendingPathComponent("state", isDirectory: true)
        let kernel = TestHelpers.createTempFile(content: "k", fileName: "kernel")
        defer { TestHelpers.removeTempItem(at: kernel) }

        let config = VMConfig(
            kernelURL: kernel, initrdURL: kernel,
            stateDirectory: stateDir
        )
        try config.ensureStateDirectory()
        try config.ensureStateDirectory()

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: stateDir.path, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)
    }
}
