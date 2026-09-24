import Foundation
import Observation

public struct DraftFields: Codable, Equatable, Sendable {
    public var name: String
    public var mode: CreationMode
    public var prompt: String
    public var params: GenerationParams
    public var referenceBindings: [ReferenceBinding]
    public var outputDirectoryID: String?

    public init(name: String = "未命名作品", mode: CreationMode = .podcast,
                prompt: String = "", params: GenerationParams = .init(),
                referenceBindings: [ReferenceBinding] = [], outputDirectoryID: String? = nil) {
        self.name = name; self.mode = mode; self.prompt = prompt
        self.params = params; self.referenceBindings = referenceBindings
        self.outputDirectoryID = outputDirectoryID
    }
}

public struct ProjectDraft: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var fields: DraftFields
    public var revision: Int
    public init(id: String = "proj_" + UUID().uuidString, fields: DraftFields, revision: Int = 1) {
        self.id = id; self.fields = fields; self.revision = revision
    }
}

public enum DraftStoreError: Error, Equatable { case conflict, missing }
public protocol DraftStore: Sendable {
    func create(_ fields: DraftFields) async throws -> ProjectDraft
    func save(_ draft: ProjectDraft, expectedRevision: Int) async throws -> ProjectDraft
}

public actor InMemoryDraftStore: DraftStore {
    private var drafts: [String: ProjectDraft] = [:]
    public init() {}
    public func create(_ fields: DraftFields) async throws -> ProjectDraft {
        let draft = ProjectDraft(fields: fields)
        drafts[draft.id] = draft
        return draft
    }
    public func save(_ draft: ProjectDraft, expectedRevision: Int) async throws -> ProjectDraft {
        guard let stored = drafts[draft.id] else { throw DraftStoreError.missing }
        guard stored.revision == expectedRevision else { throw DraftStoreError.conflict }
        var updated = draft
        updated.revision = stored.revision + 1
        drafts[draft.id] = updated
        return updated
    }
}

public enum DraftSaveState: Equatable, Sendable { case unsaved, saving, saved, conflict, failed(String) }

@MainActor @Observable
public final class DraftController {
    public private(set) var fields: DraftFields
    public private(set) var draft: ProjectDraft?
    public private(set) var state: DraftSaveState = .unsaved
    public private(set) var localRecoveryText: String?
    private let store: any DraftStore
    private var sampleUntouched: Bool
    private var editVersion = 0
    private var savedVersion = -1
    private var debounce: Task<Void, Never>?
    private var inFlight: Task<Void, Error>?

    public init(fields: DraftFields? = nil, draft: ProjectDraft? = nil, store: any DraftStore) {
        self.store = store
        self.draft = draft
        self.fields = draft?.fields ?? fields ?? DraftFields(name: "雨夜里的慢生活", prompt: Self.sample(for: .podcast))
        sampleUntouched = draft == nil && fields == nil
        if draft != nil { savedVersion = 0; state = .saved }
    }

    /// Explicit content replacement (templates and undo) never triggers mode sample substitution.
    public func replaceFields(_ replacement: DraftFields) {
        sampleUntouched = false
        change { $0 = replacement }
    }

    public func change(_ mutation: (inout DraftFields) -> Void) {
        var updated = fields
        mutation(&updated)
        guard updated != fields else { return }
        if updated.prompt != fields.prompt { sampleUntouched = false }
        if sampleUntouched && updated.mode != fields.mode { updated.prompt = Self.sample(for: updated.mode) }
        fields = updated
        editVersion += 1
        debounce?.cancel()
        if state == .conflict {
            localRecoveryText = fields.prompt
            return
        }
        if inFlight == nil { state = .unsaved }
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            try? await self?.saveNow()
        }
    }

    /// All callers join the same write, including edits made while it is in flight.
    public func saveNow() async throws {
        debounce?.cancel()
        debounce = nil
        if let inFlight { return try await inFlight.value }
        guard state != .conflict else { throw DraftStoreError.conflict }
        guard editVersion != savedVersion else { return }
        let task = Task { @MainActor in
            defer { inFlight = nil }
            state = .saving
            do {
                while savedVersion != editVersion {
                    let version = editVersion
                    let snapshot = fields
                    if var existing = draft {
                        existing.fields = snapshot
                        draft = try await store.save(existing, expectedRevision: existing.revision)
                    } else {
                        draft = try await store.create(snapshot)
                    }
                    savedVersion = version
                }
                state = .saved
            } catch {
                localRecoveryText = fields.prompt
                state = (error as? DraftStoreError) == .conflict ? .conflict : .failed(error.localizedDescription)
                throw error
            }
        }
        inFlight = task
        try await task.value
    }

    /// Explicit recovery creates a separate draft; never overwrites the conflicting version.
    public func saveRecoveryAsNewDraft() async throws {
        if let inFlight { try await inFlight.value }
        draft = nil
        savedVersion = -1
        state = .unsaved
        try await saveNow()
        localRecoveryText = nil
    }

    public static func sample(for mode: CreationMode) -> String {
        switch mode {
        case .podcast:
            "【场景】雨夜，窗边的一盏灯。\n\n【角色：讲述者】温和沉静，自然舒缓。\n\n【音效】细雨落在窗沿，轻柔、不盖过人声。\n\n【对白：讲述者】今晚，不必急着给生活一个答案。把未完成的事留给明天，先照顾好此刻的自己。\n\n【音乐】极轻的钢琴，在尾音后慢慢淡出。"
        case .advertisement:
            "【场景】清晨，明亮的房间。\n\n【角色：旁白】清晰、轻快。\n\n【对白：旁白】从一杯热茶开始，把今天过成喜欢的样子。"
        case .audiobook:
            "【角色：讲述者】从容、富有画面感。\n\n【对白：讲述者】旅人推开旧书店的门，纸张的清香从午后的光里浮起。"
        case .drama:
            "【场景】黄昏的车站。\n\n【角色：甲】轻声。\n【角色：乙】坚定。\n\n【对白：甲】你还记得那条小路吗？\n【对白：乙】当然，沿着灯光就能找到。"
        case .game:
            "【角色：向导】坚定、简洁。\n\n【音效】石门缓缓打开。\n\n【对白：向导】准备好了吗？我们的旅程才刚刚开始。"
        case .narration:
            "【角色：旁白】沉静、自然。\n\n【对白：旁白】天光越过山脊，清晨的第一阵风，吹醒了沉睡的森林。"
        case .auto:
            "【场景】请描述故事发生的地方。\n\n【角色：讲述者】请描述声音特点。\n\n【对白：讲述者】从这里开始你的创作。"
        }
    }
}
