import Foundation

enum TestHelpers {
    static func createTempDirectory() -> URL {
        let base = FileManager.default.temporaryDirectory
        let unique = ProcessInfo.processInfo.globallyUniqueString
        let dir = base.appendingPathComponent("darwin-vz-nix-tests-\(unique)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func createTempFile(content: String = "", fileName: String? = nil) -> URL {
        let dir = createTempDirectory()
        let name = fileName ?? ProcessInfo.processInfo.globallyUniqueString
        let fileURL = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data(content.utf8))
        return fileURL
    }

    static func removeTempItem(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
