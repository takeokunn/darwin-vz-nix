@testable import DarwinVZNixLib
import Foundation
import Testing

struct VMConfigTests {
    // MARK: - parseDiskSize valid inputs

    @Test
    func parseDiskSize100G() throws {
        let result = try VMConfig.parseDiskSize("100G")
        #expect(result == 100 * 1024 * 1024 * 1024)
    }

    @Test
    func parseDiskSize1T() throws {
        let result = try VMConfig.parseDiskSize("1T")
        #expect(result == 1024 * 1024 * 1024 * 1024)
    }

    @Test
    func parseDiskSize512M() throws {
        let result = try VMConfig.parseDiskSize("512M")
        #expect(result == 512 * 1024 * 1024)
    }

    // MARK: - parseDiskSize case insensitive

    @Test
    func parseDiskSizeLowercaseG() throws {
        let result = try VMConfig.parseDiskSize("100g")
        #expect(result == 100 * 1024 * 1024 * 1024)
    }

    @Test
    func parseDiskSizeLowercaseT() throws {
        let result = try VMConfig.parseDiskSize("1t")
        #expect(result == 1024 * 1024 * 1024 * 1024)
    }

    @Test
    func parseDiskSizeLowercaseM() throws {
        let result = try VMConfig.parseDiskSize("512m")
        #expect(result == 512 * 1024 * 1024)
    }

    // MARK: - parseDiskSize invalid inputs

    @Test
    func parseDiskSizeEmpty() {
        #expect(throws: VMConfigError.self) {
            try VMConfig.parseDiskSize("")
        }
    }

    @Test
    func parseDiskSizeNonNumeric() {
        #expect(throws: VMConfigError.self) {
            try VMConfig.parseDiskSize("abc")
        }
    }

    @Test
    func parseDiskSizeUnknownSuffix() {
        #expect(throws: VMConfigError.self) {
            try VMConfig.parseDiskSize("100X")
        }
    }

    @Test
    func parseDiskSizeNegative() {
        #expect(throws: VMConfigError.self) {
            try VMConfig.parseDiskSize("-1G")
        }
    }

    // MARK: - parseDiskSize raw bytes

    @Test
    func parseDiskSizeRawBytes() throws {
        let result = try VMConfig.parseDiskSize("1073741824")
        #expect(result == 1_073_741_824)
    }

    @Test
    func parseDiskSize1024K() throws {
        let result = try VMConfig.parseDiskSize("1024K")
        #expect(result == 1024 * 1024)
    }

    @Test
    func parseDiskSizeZeroG() {
        #expect(throws: VMConfigError.self) {
            try VMConfig.parseDiskSize("0G")
        }
    }

    @Test
    func parseDiskSizeOverflow() {
        #expect(throws: VMConfigError.self) {
            try VMConfig.parseDiskSize("\(UInt64.max)T")
        }
    }

    // MARK: - validate cores

    @Test
    func validateZeroCores() throws {
        let kernel = TestHelpers.createTempFile(content: "kernel")
        let initrd = TestHelpers.createTempFile(content: "initrd")
        defer {
            TestHelpers.removeTempItem(at: kernel.deletingLastPathComponent())
            TestHelpers.removeTempItem(at: initrd.deletingLastPathComponent())
        }
        let config = VMConfig(
            cores: 0, memory: 8192, diskSize: "100G",
            kernelURL: kernel, initrdURL: initrd
        )
        #expect(throws: VMConfigError.self) {
            try config.validate()
        }
    }

    // MARK: - validate memory

    @Test
    func validateInsufficientMemory() throws {
        let kernel = TestHelpers.createTempFile(content: "kernel")
        let initrd = TestHelpers.createTempFile(content: "initrd")
        defer {
            TestHelpers.removeTempItem(at: kernel.deletingLastPathComponent())
            TestHelpers.removeTempItem(at: initrd.deletingLastPathComponent())
        }
        let config = VMConfig(
            cores: 4, memory: 256, diskSize: "100G",
            kernelURL: kernel, initrdURL: initrd
        )
        #expect(throws: VMConfigError.self) {
            try config.validate()
        }
    }

    @Test
    func validateBoundaryMemory() throws {
        let kernel = TestHelpers.createTempFile(content: "kernel")
        let initrd = TestHelpers.createTempFile(content: "initrd")
        defer {
            TestHelpers.removeTempItem(at: kernel.deletingLastPathComponent())
            TestHelpers.removeTempItem(at: initrd.deletingLastPathComponent())
        }
        let config = VMConfig(
            cores: 1, memory: 512, diskSize: "1G",
            kernelURL: kernel, initrdURL: initrd
        )
        try config.validate()
    }

    // MARK: - validate kernel/initrd existence

    @Test
    func validateMissingInitrd() throws {
        let kernel = TestHelpers.createTempFile(content: "kernel")
        defer { TestHelpers.removeTempItem(at: kernel.deletingLastPathComponent()) }
        let fakeInitrd = URL(fileURLWithPath: "/nonexistent/initrd")
        let config = VMConfig(
            cores: 4, memory: 8192, diskSize: "100G",
            kernelURL: kernel, initrdURL: fakeInitrd
        )
        #expect(throws: VMConfigError.self) {
            try config.validate()
        }
    }

    @Test
    func validateMissingKernel() throws {
        let initrd = TestHelpers.createTempFile(content: "initrd")
        defer { TestHelpers.removeTempItem(at: initrd.deletingLastPathComponent()) }
        let fakeKernel = URL(fileURLWithPath: "/nonexistent/kernel")
        let config = VMConfig(
            cores: 4, memory: 8192, diskSize: "100G",
            kernelURL: fakeKernel, initrdURL: initrd
        )
        #expect(throws: VMConfigError.self) {
            try config.validate()
        }
    }

    @Test
    func validateExistingFiles() throws {
        let kernel = TestHelpers.createTempFile(content: "kernel")
        let initrd = TestHelpers.createTempFile(content: "initrd")
        defer {
            TestHelpers.removeTempItem(at: kernel.deletingLastPathComponent())
            TestHelpers.removeTempItem(at: initrd.deletingLastPathComponent())
        }
        let config = VMConfig(
            cores: 4, memory: 8192, diskSize: "100G",
            kernelURL: kernel, initrdURL: initrd
        )
        try config.validate()
    }

    @Test
    func validateKernelDirectory() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let kernelDir = tempDir.appendingPathComponent("Image", isDirectory: true)
        let initrd = tempDir.appendingPathComponent("initrd")
        try FileManager.default.createDirectory(at: kernelDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: initrd.path, contents: Data("initrd".utf8))

        let config = VMConfig(
            cores: 4, memory: 8192, diskSize: "100G",
            kernelURL: kernelDir, initrdURL: initrd
        )
        #expect(throws: VMConfigError.self) {
            try config.validate()
        }
    }

    @Test
    func validateSystemMissingInit() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        let kernel = tempDir.appendingPathComponent("Image")
        let initrd = tempDir.appendingPathComponent("initrd")
        let system = tempDir.appendingPathComponent("system", isDirectory: true)
        FileManager.default.createFile(atPath: kernel.path, contents: Data("kernel".utf8))
        FileManager.default.createFile(atPath: initrd.path, contents: Data("initrd".utf8))
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)

        let config = VMConfig(
            cores: 4, memory: 8192, diskSize: "100G",
            kernelURL: kernel, initrdURL: initrd, systemURL: system
        )
        #expect(throws: VMConfigError.self) {
            try config.validate()
        }
    }

    @Test
    func ensureStateDirectoryRejectsFile() throws {
        let stateFile = TestHelpers.createTempFile(content: "not a directory")
        defer { TestHelpers.removeTempItem(at: stateFile.deletingLastPathComponent()) }

        let config = VMConfig(
            kernelURL: URL(fileURLWithPath: "/fake/kernel"),
            initrdURL: URL(fileURLWithPath: "/fake/initrd"),
            stateDirectory: stateFile
        )

        #expect(throws: VMConfigError.self) {
            try config.ensureStateDirectory()
        }
    }

    // MARK: - validate kernel/initrd hint detection

    @Test
    func validateMissingInitrdWithKernelArtifactHint() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        // Create "Image" (kernel artifact) in the same directory where initrd is expected
        let imageFile = tempDir.appendingPathComponent("Image")
        FileManager.default.createFile(atPath: imageFile.path, contents: Data("kernel".utf8))

        // Create a real kernel file in a separate directory
        let kernel = TestHelpers.createTempFile(content: "kernel")
        defer { TestHelpers.removeTempItem(at: kernel.deletingLastPathComponent()) }

        let fakeInitrd = tempDir.appendingPathComponent("initrd")
        let config = VMConfig(
            cores: 4, memory: 8192, diskSize: "100G",
            kernelURL: kernel, initrdURL: fakeInitrd
        )

        do {
            try config.validate()
            Issue.record("Expected initrdNotFound to be thrown")
        } catch let error as VMConfigError {
            if case let .initrdNotFound(_, hint) = error {
                #expect(hint != nil)
                #expect(hint?.contains("Image") == true)
            } else {
                Issue.record("Expected initrdNotFound but got \(error)")
            }
        }
    }

    @Test
    func validateMissingKernelWithInitrdArtifactHint() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        // Create "initrd" (initrd artifact) in the same directory where kernel is expected
        let initrdFile = tempDir.appendingPathComponent("initrd")
        FileManager.default.createFile(atPath: initrdFile.path, contents: Data("initrd".utf8))

        // Create a real initrd file in a separate directory
        let initrd = TestHelpers.createTempFile(content: "initrd")
        defer { TestHelpers.removeTempItem(at: initrd.deletingLastPathComponent()) }

        let fakeKernel = tempDir.appendingPathComponent("Image")
        let config = VMConfig(
            cores: 4, memory: 8192, diskSize: "100G",
            kernelURL: fakeKernel, initrdURL: initrd
        )

        do {
            try config.validate()
            Issue.record("Expected kernelNotFound to be thrown")
        } catch let error as VMConfigError {
            if case let .kernelNotFound(_, hint) = error {
                #expect(hint != nil)
                #expect(hint?.contains("initrd") == true)
            } else {
                Issue.record("Expected kernelNotFound but got \(error)")
            }
        }
    }

    @Test
    func validateMissingInitrdWithoutHint() throws {
        let tempDir = TestHelpers.createTempDirectory()
        defer { TestHelpers.removeTempItem(at: tempDir) }

        // Create a real kernel file in a separate directory
        let kernel = TestHelpers.createTempFile(content: "kernel")
        defer { TestHelpers.removeTempItem(at: kernel.deletingLastPathComponent()) }

        // Point initrdURL to a file in the empty temp directory (no Image file present)
        let fakeInitrd = tempDir.appendingPathComponent("initrd")
        let config = VMConfig(
            cores: 4, memory: 8192, diskSize: "100G",
            kernelURL: kernel, initrdURL: fakeInitrd
        )

        do {
            try config.validate()
            Issue.record("Expected initrdNotFound to be thrown")
        } catch let error as VMConfigError {
            if case let .initrdNotFound(_, hint) = error {
                #expect(hint == nil)
            } else {
                Issue.record("Expected initrdNotFound but got \(error)")
            }
        }
    }

    @Test
    func errorDescriptionIncludesHint() throws {
        let error = VMConfigError.initrdNotFound(
            URL(fileURLWithPath: "/test/initrd"), hint: "test hint"
        )
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("test hint"))
    }

    // MARK: - Computed paths

    @Test
    func diskImageURLPath() {
        let stateDir = URL(fileURLWithPath: "/tmp/test-state")
        let config = VMConfig(
            kernelURL: URL(fileURLWithPath: "/fake/kernel"),
            initrdURL: URL(fileURLWithPath: "/fake/initrd"),
            stateDirectory: stateDir
        )
        #expect(config.diskImageURL.lastPathComponent == "disk.img")
        #expect(config.diskImageURL.path.hasPrefix(stateDir.path))
    }

    @Test
    func pidFileURLPath() {
        let stateDir = URL(fileURLWithPath: "/tmp/test-state")
        let config = VMConfig(
            kernelURL: URL(fileURLWithPath: "/fake/kernel"),
            initrdURL: URL(fileURLWithPath: "/fake/initrd"),
            stateDirectory: stateDir
        )
        #expect(config.pidFileURL.lastPathComponent == "vm.pid")
    }

    @Test
    func consoleLogURLPath() {
        let stateDir = URL(fileURLWithPath: "/tmp/test-state")
        let config = VMConfig(
            kernelURL: URL(fileURLWithPath: "/fake/kernel"),
            initrdURL: URL(fileURLWithPath: "/fake/initrd"),
            stateDirectory: stateDir
        )
        #expect(config.consoleLogURL.lastPathComponent == "console.log")
    }

    @Test
    func guestIPFileURLPath() {
        let stateDir = URL(fileURLWithPath: "/tmp/test-state")
        let config = VMConfig(
            kernelURL: URL(fileURLWithPath: "/fake/kernel"),
            initrdURL: URL(fileURLWithPath: "/fake/initrd"),
            stateDirectory: stateDir
        )
        #expect(config.guestIPFileURL.lastPathComponent == "guest-ip")
    }

    @Test
    func sshKeyURLPath() {
        let stateDir = URL(fileURLWithPath: "/tmp/test-state")
        let config = VMConfig(
            kernelURL: URL(fileURLWithPath: "/fake/kernel"),
            initrdURL: URL(fileURLWithPath: "/fake/initrd"),
            stateDirectory: stateDir
        )
        #expect(config.sshKeyURL.path.hasSuffix("/ssh/id_ed25519"))
    }

    @Test
    func sshDirectoryPath() {
        let stateDir = URL(fileURLWithPath: "/tmp/test-state")
        let config = VMConfig(
            kernelURL: URL(fileURLWithPath: "/fake/kernel"),
            initrdURL: URL(fileURLWithPath: "/fake/initrd"),
            stateDirectory: stateDir
        )
        #expect(config.sshDirectory.path.hasSuffix("/ssh"))
    }

    // MARK: - defaultStateDirectory and defaultPIDFileURL

    @Test
    func defaultStateDirectoryPath() {
        #expect(VMConfig.defaultStateDirectory.path.hasSuffix(".local/share/darwin-vz-nix"))
    }

    @Test
    func defaultPIDFileURLPath() {
        #expect(VMConfig.defaultPIDFileURL.lastPathComponent == "vm.pid")
    }

    // MARK: - Static path helpers

    @Test
    func staticSSHKeyURL() {
        let stateDir = URL(fileURLWithPath: "/tmp/test-state")
        let url = VMConfig.sshKeyURL(for: stateDir)
        #expect(url.path.hasSuffix("/ssh/id_ed25519"))
        #expect(url.path.hasPrefix(stateDir.path))
    }

    @Test
    func staticSSHDirectory() {
        let stateDir = URL(fileURLWithPath: "/tmp/test-state")
        let url = VMConfig.sshDirectory(for: stateDir)
        #expect(url.path.hasSuffix("/ssh"))
        #expect(url.path.hasPrefix(stateDir.path))
    }

    @Test
    func staticGuestIPFileURL() {
        let stateDir = URL(fileURLWithPath: "/tmp/test-state")
        let url = VMConfig.guestIPFileURL(for: stateDir)
        #expect(url.lastPathComponent == "guest-ip")
        #expect(url.path.hasPrefix(stateDir.path))
    }

    // MARK: - VMConfigError.errorDescription

    @Test
    func errorDescriptionInvalidCoreCount() throws {
        let error = VMConfigError.invalidCoreCount(0)
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("0"))
        #expect(desc.contains("core"))
    }

    @Test
    func errorDescriptionInsufficientMemory() throws {
        let error = VMConfigError.insufficientMemory(256)
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("256"))
        #expect(desc.contains("memory"))
    }

    @Test
    func errorDescriptionKernelNotFound() throws {
        let error = VMConfigError.kernelNotFound(URL(fileURLWithPath: "/test/kernel"), hint: nil)
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("/test/kernel"))
    }

    @Test
    func errorDescriptionInitrdNotFound() throws {
        let error = VMConfigError.initrdNotFound(URL(fileURLWithPath: "/test/initrd"), hint: nil)
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("/test/initrd"))
    }

    @Test
    func errorDescriptionInvalidDiskSize() throws {
        let error = VMConfigError.invalidDiskSize("bad")
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("bad"))
    }

    @Test
    func errorDescriptionStateDirectoryCreationFailed() throws {
        let error = VMConfigError.stateDirectoryCreationFailed("/failed/path")
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("/failed/path"))
    }
}
