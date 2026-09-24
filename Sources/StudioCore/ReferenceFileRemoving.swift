import Foundation

public protocol ReferenceFileRemoving: Sendable {
    func remove(_ url: URL) throws
}
public struct LocalReferenceFileRemover: ReferenceFileRemoving {
    public init() {}
    public func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
}
