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
    public let rootIdentity: FileIdentity?
    public init(id: String, version: Int, bookmark: Data, rootIdentity: FileIdentity? = nil) {
        self.id = id; self.version = version; self.bookmark = bookmark; self.rootIdentity = rootIdentity
    }
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

public struct JobMetadata: Equatable, Sendable {
    public let name: String
    public let favorite: Bool
    public let note: String
    public init(name: String = "", favorite: Bool = false, note: String = "") {
        self.name = name; self.favorite = favorite; self.note = note
    }
}

public struct LibraryFilter: Sendable {
    public var search: String
    public var mode: CreationMode?
    public var state: JobState?
    public var favoriteOnly: Bool
    public var since: Date?
    public var beforeID: String?
    public var limit: Int
    public init(search: String = "", mode: CreationMode? = nil, state: JobState? = nil,
                favoriteOnly: Bool = false, since: Date? = nil, beforeID: String? = nil, limit: Int = 50) {
        self.search = search; self.mode = mode; self.state = state; self.favoriteOnly = favoriteOnly
        self.since = since; self.beforeID = beforeID; self.limit = limit
    }
}

public struct LibraryItem: Sendable {
    public let job: StoredJob
    public let project: ProjectDraft
    public let metadata: JobMetadata
    public let createdAt: Date
    public let isFinal: Bool
}

public struct LibraryPage: Sendable {
    public let items: [LibraryItem]
    public let nextBeforeID: String?
}

/// Worker-only receipt. Keep out of exports and list rows: the URL can contain a
/// short-lived signature. Diagnostics intentionally never print its fields.
public struct ProviderResponseSnapshot: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let providerRequestID: String
    public let audioURL: URL
    public let receivedAt: Date
    public let expiresAt: Date
    public init(providerRequestID: String, audioURL: URL, receivedAt: Date = Date(), expiresAt: Date? = nil) {
        self.providerRequestID = providerRequestID; self.audioURL = audioURL; self.receivedAt = receivedAt
        self.expiresAt = expiresAt ?? receivedAt.addingTimeInterval(24 * 3600)
    }
    private enum CodingKeys: String, CodingKey { case providerRequestID, audioURL, receivedAt, expiresAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        providerRequestID = try values.decode(String.self, forKey: .providerRequestID)
        audioURL = try values.decode(URL.self, forKey: .audioURL)
        receivedAt = try values.decode(Date.self, forKey: .receivedAt)
        expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt) ?? receivedAt.addingTimeInterval(24 * 3600)
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
    public let fileIdentity: FileIdentity?
    public init(id: String, jobID: String, directoryID: String, relativePath: String, kind: String, appOwned: Bool, fileIdentity: FileIdentity? = nil) {
        self.id = id; self.jobID = jobID; self.directoryID = directoryID; self.relativePath = relativePath
        self.kind = kind; self.appOwned = appOwned; self.fileIdentity = fileIdentity
    }
}

/// File identity prevents a replaced path from becoming an application-owned file.
public struct FileIdentity: Codable, Equatable, Sendable {
    public let device: Int32
    public let inode: UInt64
    public init(device: Int32, inode: UInt64) { self.device = device; self.inode = inode }
}
public struct JobOutputFolder: Equatable, Sendable {
    public let jobID: String
    public let directoryID: String
    public let relativePath: String
    public let identity: FileIdentity
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
