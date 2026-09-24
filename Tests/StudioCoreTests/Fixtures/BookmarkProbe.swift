import Foundation

/// Compiled with the production bookmark adapter; each invocation is a fresh
/// process with the same signing identity. Inputs are UUID temporary fixtures.
@main struct BookmarkProbe {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { exit(64) }
        let root = URL(fileURLWithPath: arguments[2]).resolvingSymlinksInPath()
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard root.deletingLastPathComponent() == temp, UUID(uuidString: root.lastPathComponent) != nil else { exit(65) }
        let provider = SecurityScopedBookmarks()
        let bookmark = root.appendingPathComponent("authorization.bookmark")
        if arguments[1] == "create" {
            let directory = root.appendingPathComponent("中文 空格 跨进程", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let started = provider.start(directory)
            defer { if started { provider.stop(directory) } }
            try provider.create(for: directory).write(to: bookmark)
            print("created scoped bookmark")
        } else if arguments[1] == "resolve" {
            let result = try provider.resolve(Data(contentsOf: bookmark))
            guard provider.start(result.url) else { exit(66) }
            defer { provider.stop(result.url) }
            let probe = result.url.appendingPathComponent("probe-" + UUID().uuidString)
            try Data("synthetic".utf8).write(to: probe, options: .withoutOverwriting)
            guard try Data(contentsOf: probe) == Data("synthetic".utf8) else { exit(67) }
            try FileManager.default.removeItem(at: probe)
            print("resolved scoped bookmark; actual write passed; stale=\(result.stale)")
        } else { exit(64) }
    }
}
