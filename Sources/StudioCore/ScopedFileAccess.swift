import Foundation
import Darwin

/// All descendant traversal uses O_NOFOLLOW and directory-relative syscalls.
/// Never recursively moves a folder: unregistered files remain where they are.
final class ScopedFileAccess {
    let fd: Int32
    init(url: URL) throws {
        fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OutputDirectoryError.unavailable }
    }
    deinit { Darwin.close(fd) }

    func rootIdentity() throws -> FileIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw OutputDirectoryError.unavailable }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") }) else { throw OutputDirectoryError.invalidPath }
        return parts
    }
    private func parent(_ path: String) throws -> (Int32, String) {
        let parts = try Self.components(path)
        var current = dup(fd)
        guard current >= 0 else { throw OutputDirectoryError.unavailable }
        do {
            for part in parts.dropLast() {
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw OutputDirectoryError.invalidPath }
                Darwin.close(current); current = next
            }
            // An already-open child may have been renamed. Check its actual
            // location again before any syscall that can modify a file.
            let rootPath = try descriptorPath(fd)
            let parentPath = try descriptorPath(current)
            guard parentPath == rootPath || parentPath.hasPrefix(rootPath + "/") else { throw OutputDirectoryError.invalidPath }
            return (current, parts.last!)
        } catch { Darwin.close(current); throw error }
    }
    private func descriptorPath(_ descriptor: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { throw OutputDirectoryError.unavailable }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    func identity(_ path: String, directory: Bool = false) throws -> FileIdentity {
        let (parent, name) = try parent(path); defer { Darwin.close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || info.st_nlink == 1 else { throw OutputDirectoryError.invalidPath }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }
    func exists(_ path: String) throws -> Bool {
        let (parent, name) = try parent(path); defer { Darwin.close(parent) }
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw OutputDirectoryError.unavailable }
        return false
    }
    func mkdir(_ path: String) throws -> FileIdentity {
        let (parent, name) = try parent(path); defer { Darwin.close(parent) }
        guard mkdirat(parent, name, 0o700) == 0 else { throw errno == EEXIST ? OutputDirectoryError.conflict : OutputDirectoryError.unavailable }
        return try identity(path, directory: true)
    }
    func ensureDirectory(_ path: String) throws {
        if try !exists(path) { _ = try mkdir(path) }
        _ = try identity(path, directory: true)
    }
    func removeEmptyDirectory(_ path: String) throws {
        let (parent, name) = try parent(path); defer { Darwin.close(parent) }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw OutputDirectoryError.unavailable }
    }
    func write(_ data: Data, path: String) throws -> FileIdentity {
        let (parent, name) = try parent(path); defer { Darwin.close(parent) }
        let file = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw errno == EEXIST ? OutputDirectoryError.conflict : OutputDirectoryError.unavailable }
        defer { Darwin.close(file) }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw OutputDirectoryError.unavailable }
                    offset += count
                }
            }
            guard fsync(file) == 0 else { throw OutputDirectoryError.unavailable }
            var info = stat()
            guard fstat(file, &info) == 0 else { throw OutputDirectoryError.unavailable }
            return FileIdentity(device: info.st_dev, inode: info.st_ino)
        } catch {
            // This O_EXCL-created file belongs to this failed write, never to the user.
            unlinkat(parent, name, 0)
            throw error
        }
    }
    func probe(_ directory: String? = nil) throws {
        let name = ".qwen-write-probe-" + UUID().uuidString
        let path = directory.map { $0 + "/" + name } ?? name
        let expected = try write(Data([0x51]), path: path)
        let (parent, leaf) = try parent(path); defer { Darwin.close(parent) }
        guard try identity(path) == expected, unlinkat(parent, leaf, 0) == 0 else { throw OutputDirectoryError.unavailable }
    }
    func move(source: String, destination: String, identity expected: FileIdentity) throws {
        guard try identity(source) == expected else { throw OutputDirectoryError.invalidPath }
        let (sourceParent, sourceName) = try parent(source); defer { Darwin.close(sourceParent) }
        let (destinationParent, destinationName) = try parent(destination); defer { Darwin.close(destinationParent) }
        // Exclusive rename is atomic and cannot overwrite a competing user file.
        guard renameatx_np(sourceParent, sourceName, destinationParent, destinationName, UInt32(RENAME_EXCL)) == 0 else {
            throw errno == EEXIST ? OutputDirectoryError.conflict : OutputDirectoryError.unavailable
        }
        guard try identity(destination) == expected else { throw OutputDirectoryError.invalidPath }
        _ = fsync(sourceParent); _ = fsync(destinationParent)
    }
}
