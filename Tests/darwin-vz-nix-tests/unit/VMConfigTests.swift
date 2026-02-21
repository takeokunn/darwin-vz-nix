@testable import darwin_vz_nix
import Foundation
import Testing

@Suite("VMConfig", .tags(.unit))
struct VMConfigTests {
    // MARK: - parseDiskSize valid inputs

    @Test("parseDiskSize parses 100G to correct byte value")
    func parseDiskSize100G() throws {
        let result = try VMConfig.parseDiskSize("100G")
        #expect(result == 100 * 1024 * 1024 * 1024)
    }

    @Test("parseDiskSize parses 1T to correct byte value")
    func parseDiskSize1T() throws {
        let result = try VMConfig.parseDiskSize("1T")
        #expect(result == 1024 * 1024 * 1024 * 1024)
    }

    @Test("parseDiskSize parses 512M to correct byte value")
    func parseDiskSize512M() throws {
        let result = try VMConfig.parseDiskSize("512M")
        #expect(result == 512 * 1024 * 1024)
    }

    // MARK: - parseDiskSize case insensitive

    @Test("parseDiskSize handles lowercase 100g")
    func parseDiskSizeLowercaseG() throws {
        let result = try VMConfig.parseDiskSize("100g")
        #expect(result == 100 * 1024 * 1024 * 1024)
    }

    @Test("parseDiskSize handles lowercase 1t")
    func parseDiskSizeLowercaseT() throws {
        let result = try VMConfig.parseDiskSize("1t")
        #expect(result == 1024 * 1024 * 1024 * 1024)
    }

    @Test("parseDiskSize handles lowercase 512m")
    func parseDiskSizeLowercaseM() throws {
        let result = try VMConfig.parseDiskSize("512m")
        #expect(result == 512 * 1024 * 1024)
    }

    // MARK: - parseDiskSize invalid inputs

    @Test("parseDiskSize throws invalidDiskSize for empty string")
    func parseDiskSizeEmpty() {
        #expect(throws: VMConfigError.self) {
            try VMConfig.parseDiskSize("")
        }
    }

    @Test("parseDiskSize throws invalidDiskSize for non-numeric input")
    func parseDiskSizeNonNumeric() {
        #expect(throws: VMConfigError.self) {
            try VMConfig.parseDiskSize("abc")
        }
    }

    @Test("parseDiskSize throws invalidDiskSize for unknown suffix")
    func parseDiskSizeUnknownSuffix() {
        #expect(throws: VMConfigError.self) {
            try VMConfig.parseDiskSize("100X")
        }
    }

    @Test("parseDiskSize throws invalidDiskSize for negative value")
    func parseDiskSizeNegative() {
        #expect(throws: VMConfigError.self) {
            try VMConfig.parseDiskSize("-1G")
        }
    }

    // MARK: - parseDiskSize raw bytes

    @Test("parseDiskSize parses raw bytes without suffix")
    func parseDiskSizeRawBytes() throws {
        let result = try VMConfig.parseDiskSize("1073741824")
        #expect(result == 1_073_741_824)
    }

    @Test("parseDiskSize parses 1024K to correct byte value")
    func parseDiskSize1024K() throws {
        let result = try VMConfig.parseDiskSize("1024K")
        #expect(result == 1024 * 1024)
    }

    @Test("parseDiskSize throws invalidDiskSize for zero value with suffix")
    func parseDiskSizeZeroG() {
        #expect(throws: VMConfigError.self) {
            try VMConfig.parseDiskSize("0G")
        }
    }

    // MARK: - validate cores

    @Test("validate throws invalidCoreCount for zero cores")
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

    @Test("validate throws insufficientMemory for 256 MB")
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

    @Test("validate succeeds with boundary memory of 512 MB")
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

    @Test("validate throws initrdNotFound when kernel exists but initrd is missing")
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

    @Test("validate throws kernelNotFound for missing kernel file")
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

    @Test("validate succeeds when kernel and initrd exist")
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

    // MARK: - Computed paths

    @Test("diskImageURL ends with disk.img")
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

    @Test("pidFileURL ends with vm.pid")
    func pidFileURLPath() {
        let stateDir = URL(fileURLWithPath: "/tmp/test-state")
        let config = VMConfig(
            kernelURL: URL(fileURLWithPath: "/fake/kernel"),
            initrdURL: URL(fileURLWithPath: "/fake/initrd"),
            stateDirectory: stateDir
        )
        #expect(config.pidFileURL.lastPathComponent == "vm.pid")
    }

    @Test("consoleLogURL ends with console.log")
    func consoleLogURLPath() {
        let stateDir = URL(fileURLWithPath: "/tmp/test-state")
        let config = VMConfig(
            kernelURL: URL(fileURLWithPath: "/fake/kernel"),
            initrdURL: URL(fileURLWithPath: "/fake/initrd"),
            stateDirectory: stateDir
        )
        #expect(config.consoleLogURL.lastPathComponent == "console.log")
    }

    @Test("guestIPFileURL ends with guest-ip")
    func guestIPFileURLPath() {
        let stateDir = URL(fileURLWithPath: "/tmp/test-state")
        let config = VMConfig(
            kernelURL: URL(fileURLWithPath: "/fake/kernel"),
            initrdURL: URL(fileURLWithPath: "/fake/initrd"),
            stateDirectory: stateDir
        )
        #expect(config.guestIPFileURL.lastPathComponent == "guest-ip")
    }

    @Test("sshKeyURL path contains ssh/id_ed25519")
    func sshKeyURLPath() {
        let stateDir = URL(fileURLWithPath: "/tmp/test-state")
        let config = VMConfig(
            kernelURL: URL(fileURLWithPath: "/fake/kernel"),
            initrdURL: URL(fileURLWithPath: "/fake/initrd"),
            stateDirectory: stateDir
        )
        #expect(config.sshKeyURL.path.hasSuffix("/ssh/id_ed25519"))
    }

    @Test("sshDirectory path ends with ssh")
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

    @Test("defaultStateDirectory ends with .local/share/darwin-vz-nix")
    func defaultStateDirectoryPath() {
        #expect(VMConfig.defaultStateDirectory.path.hasSuffix(".local/share/darwin-vz-nix"))
    }

    @Test("defaultPIDFileURL ends with vm.pid")
    func defaultPIDFileURLPath() {
        #expect(VMConfig.defaultPIDFileURL.lastPathComponent == "vm.pid")
    }

    // MARK: - Static path helpers

    @Test("sshKeyURL(for:) produces correct path")
    func staticSSHKeyURL() {
        let stateDir = URL(fileURLWithPath: "/tmp/test-state")
        let url = VMConfig.sshKeyURL(for: stateDir)
        #expect(url.path.hasSuffix("/ssh/id_ed25519"))
        #expect(url.path.hasPrefix(stateDir.path))
    }

    @Test("sshDirectory(for:) produces correct path")
    func staticSSHDirectory() {
        let stateDir = URL(fileURLWithPath: "/tmp/test-state")
        let url = VMConfig.sshDirectory(for: stateDir)
        #expect(url.path.hasSuffix("/ssh"))
        #expect(url.path.hasPrefix(stateDir.path))
    }

    @Test("guestIPFileURL(for:) produces correct path")
    func staticGuestIPFileURL() {
        let stateDir = URL(fileURLWithPath: "/tmp/test-state")
        let url = VMConfig.guestIPFileURL(for: stateDir)
        #expect(url.lastPathComponent == "guest-ip")
        #expect(url.path.hasPrefix(stateDir.path))
    }

    // MARK: - VMConfigError.errorDescription

    @Test("invalidCoreCount error description is non-nil and contains core count")
    func errorDescriptionInvalidCoreCount() throws {
        let error = VMConfigError.invalidCoreCount(0)
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(try #require(desc?.contains("0")))
        #expect(try #require(desc?.contains("core")))
    }

    @Test("insufficientMemory error description is non-nil and contains memory value")
    func errorDescriptionInsufficientMemory() throws {
        let error = VMConfigError.insufficientMemory(256)
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(try #require(desc?.contains("256")))
        #expect(try #require(desc?.contains("memory")))
    }

    @Test("kernelNotFound error description is non-nil and contains path")
    func errorDescriptionKernelNotFound() throws {
        let error = VMConfigError.kernelNotFound(URL(fileURLWithPath: "/test/kernel"))
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(try #require(desc?.contains("/test/kernel")))
    }

    @Test("initrdNotFound error description is non-nil and contains path")
    func errorDescriptionInitrdNotFound() throws {
        let error = VMConfigError.initrdNotFound(URL(fileURLWithPath: "/test/initrd"))
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(try #require(desc?.contains("/test/initrd")))
    }

    @Test("invalidDiskSize error description is non-nil and contains size string")
    func errorDescriptionInvalidDiskSize() throws {
        let error = VMConfigError.invalidDiskSize("bad")
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(try #require(desc?.contains("bad")))
    }

    @Test("stateDirectoryCreationFailed error description is non-nil and contains path")
    func errorDescriptionStateDirectoryCreationFailed() throws {
        let error = VMConfigError.stateDirectoryCreationFailed("/failed/path")
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(try #require(desc?.contains("/failed/path")))
    }
}
