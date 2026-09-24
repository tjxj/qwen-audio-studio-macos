import Foundation

public enum OutputDirectoryError: Error, Equatable, Sendable {
    case unregistered, reauthorizationRequired, unavailable, invalidPath, conflict, closed
}
public struct BookmarkResolution: Sendable {
    public let url: URL
    public let stale: Bool
    public init(url: URL, stale: Bool) { self.url = url; self.stale = stale }
}
public protocol DirectoryBookmarking: Sendable {
    func create(for url: URL) throws -> Data
    func resolve(_ data: Data) throws -> BookmarkResolution
    func start(_ url: URL) -> Bool
    func stop(_ url: URL)
}
public struct SecurityScopedBookmarks: DirectoryBookmarking {
    public init() {}
    private struct Envelope: Codable { let scoped: Data; let location: Data }
    public func create(for url: URL) throws -> Data {
        let scoped = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let location = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return try JSONEncoder().encode(Envelope(scoped: scoped, location: location))
    }
    public func resolve(_ data: Data) throws -> BookmarkResolution {
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            var stale = false
            let url = try URL(resolvingBookmarkData: envelope.scoped, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
            return BookmarkResolution(url: url, stale: stale)
        } catch { throw OutputDirectoryError.reauthorizationRequired }
    }
    /// Location is only a hint for the next picker. It never grants access.
    public func locationHint(_ data: Data) -> URL? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: envelope.location, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
    public func start(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stop(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}
