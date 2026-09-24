import Foundation
public struct ReferenceLeaseStore: Sendable {
    let store: StudioStore
    public init(store: StudioStore) { self.store = store }
    public func acquire(_ referenceID: String, forJob job: String) async throws { try await store.acquireReference(referenceID, forJob: job) }
    public func release(job: String) async throws { try await store.releaseReferences(jobID: job) }
}
