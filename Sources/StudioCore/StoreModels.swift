import Foundation
import CryptoKit

public enum StudioStoreError: Error, Equatable, Sendable {
    case closed, invalidSubmission, requestConflict, staleDirectory, staleReference, missingConsent, expiredConsent
    case missing, corruptRecord, invalidTransition, invalidPath, unsupportedSchema(Int)
}

public struct DirectorySnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let version: Int
    public let bookmark: Data
    public init(id: String, version: Int, bookmark: Data) { self.id = id; self.version = version; self.bookmark = bookmark }
}

public struct ReferenceSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let contentHash: String
    public let fileName: String
    public let duration: Double
    public let relativePath: String
    public let temporary: Bool
    public init(id: String, contentHash: String, fileName: String, duration: Double, relativePath: String = "", temporary: Bool = true) {
        self.id = id; self.contentHash = contentHash; self.fileName = fileName; self.duration = duration
        self.relativePath = relativePath; self.temporary = temporary
    }
}

/// A new confirmation bound to this request and these exact files; no reusable global consent.
public struct UploadConsent: Codable, Equatable, Sendable {
    public let clientRequestID: String
    public let references: [ReferenceSnapshot]
    public let confirmed: Bool
    public let confirmedAt: Date
    public let expiresAt: Date
    public init(clientRequestID: String, references: [ReferenceSnapshot], confirmed: Bool, confirmedAt: Date = Date()) {
        self.clientRequestID = clientRequestID; self.references = references; self.confirmed = confirmed
        self.confirmedAt = confirmedAt; self.expiresAt = confirmedAt.addingTimeInterval(600)
    }
}

public struct BatchSubmission: Codable, Equatable, Sendable {
    public let clientRequestID: String
    public let project: ProjectDraft
    public let compiledPrompt: String
    public let candidateSeeds: [Int]
    public let directory: DirectorySnapshot
    public let references: [ReferenceSnapshot]
    public let consent: UploadConsent
    public init(clientRequestID: String, project: ProjectDraft, compiledPrompt: String, candidateSeeds: [Int],
                directory: DirectorySnapshot, references: [ReferenceSnapshot], consent: UploadConsent) {
        self.clientRequestID = clientRequestID; self.project = project; self.compiledPrompt = compiledPrompt
        self.candidateSeeds = candidateSeeds; self.directory = directory; self.references = references; self.consent = consent
    }
    /// Derived from the complete snapshot; callers cannot accidentally reuse a hash for a changed body.
    public func requestHash() throws -> String { SHA256.hash(data: try storeEncode(self)).map { String(format: "%02x", $0) }.joined() }
}

public struct StoredBatch: Equatable, Sendable, Identifiable {
    public let id: String
    public let requestHash: String
    public let submission: BatchSubmission
    public let jobIDs: [String]
}

public enum JobState: String, Codable, Sendable {
    case queued, preparing, requesting, downloading, validating, success, failed, cancelled, interrupted
    public var isTerminal: Bool { [.success, .failed, .cancelled, .interrupted].contains(self) }
}
public struct StoredJob: Equatable, Sendable, Identifiable {
    public let id: String
    public let batchID: String
    public let candidateIndex: Int
    public let seed: Int
    public let state: JobState
    public let resultUncertain: Bool
    public let message: String?
}

/// Worker-only receipt. Keep out of exports and list rows: the URL can contain a
/// short-lived signature. Diagnostics intentionally never print its fields.
public struct ProviderResponseSnapshot: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let providerRequestID: String
    public let audioURL: URL
    public let receivedAt: Date
    public init(providerRequestID: String, audioURL: URL, receivedAt: Date = Date()) {
        self.providerRequestID = providerRequestID; self.audioURL = audioURL; self.receivedAt = receivedAt
    }
    public var description: String { "ProviderResponseSnapshot(<redacted>)" }
    public var debugDescription: String { description }
}

public struct StoredAsset: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let jobID: String
    public let directoryID: String
    public let relativePath: String
    public let kind: String
    public let appOwned: Bool
    public init(id: String, jobID: String, directoryID: String, relativePath: String, kind: String, appOwned: Bool) {
        self.id = id; self.jobID = jobID; self.directoryID = directoryID; self.relativePath = relativePath
        self.kind = kind; self.appOwned = appOwned
    }
}
public struct FileOperation: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case trash, restore }
    public let id: String
    public let assetID: String
    public let sourceRelativePath: String
    public let destinationRelativePath: String
    public let kind: Kind
    public init(id: String, assetID: String, sourceRelativePath: String, destinationRelativePath: String, kind: Kind) {
        self.id = id; self.assetID = assetID; self.sourceRelativePath = sourceRelativePath
        self.destinationRelativePath = destinationRelativePath; self.kind = kind
    }
}

func storeEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}
func storeDecode<T: Decodable>(_ type: T.Type, _ value: SQLiteValue) throws -> T {
    guard let data = value.data else { throw StudioStoreError.corruptRecord }
    return try JSONDecoder().decode(type, from: data)
}
