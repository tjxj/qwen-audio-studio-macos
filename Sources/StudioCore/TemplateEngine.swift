import Foundation

public enum TemplateValue: Codable, Equatable, Sendable {
    case text(String), number(Double)
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) { self = .text(text) }
        else { self = .number(try value.decode(Double.self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self { case .text(let text): try value.encode(text); case .number(let number): try value.encode(number) }
    }
    public var display: String {
        switch self {
        case .text(let text): text
        case .number(let number): number.isFinite && number.rounded() == number ? String(format: "%.0f", number) : String(number)
        }
    }
}

public struct TemplateVariable: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case text, number, select }
    public var id: String { key }
    public var key: String
    public var label: String
    public var type: Kind
    public var required: Bool
    public var defaultValue: TemplateValue
    public var maxLength: Int?
    public var min: Double?
    public var max: Double?
    public var options: [String]?
    enum CodingKeys: String, CodingKey {
        case key, label, type, required, min, max, options
        case defaultValue = "default", maxLength = "max_length"
    }
    public init(key: String, label: String, type: Kind, required: Bool = true, defaultValue: TemplateValue,
                maxLength: Int? = nil, min: Double? = nil, max: Double? = nil, options: [String]? = nil) {
        self.key = key; self.label = label; self.type = type; self.required = required
        self.defaultValue = defaultValue; self.maxLength = maxLength; self.min = min; self.max = max; self.options = options
    }
}

public struct StudioTemplate: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var source: String
    public var version: Int
    public var name: String
    public var mode: CreationMode
    public var description: String
    public var tags: [String]
    public var roleCount: Int
    public var suggestedDurationSeconds: Int?
    public var promptPattern: String
    public var variables: [TemplateVariable]
    enum CodingKeys: String, CodingKey {
        case id, source, version, name, mode, description, tags, variables
        case roleCount = "role_count", suggestedDurationSeconds = "suggested_duration_seconds", promptPattern = "prompt_pattern"
    }
    public var isBuiltin: Bool { source == "builtin" }
    public init(id: String = "user-" + UUID().uuidString, source: String = "user", version: Int = 1,
                name: String, mode: CreationMode, description: String = "", tags: [String] = [],
                roleCount: Int = 1, suggestedDurationSeconds: Int? = nil, promptPattern: String,
                variables: [TemplateVariable] = []) {
        self.id = id; self.source = source; self.version = version; self.name = name; self.mode = mode
        self.description = description; self.tags = tags; self.roleCount = roleCount
        self.suggestedDurationSeconds = suggestedDurationSeconds; self.promptPattern = promptPattern; self.variables = variables
    }
}

public enum TemplateError: Error, Equatable, LocalizedError {
    case invalid(String), missing, readOnly
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .missing: "未找到该模板，请重新选择。"
        case .readOnly: "内置模板为只读，请创建自己的副本。"
        }
    }
}

public struct TemplatePreview: Equatable, Sendable {
    public let templateID: String
    public let name: String
    public let mode: CreationMode
    public let prompt: String
    public let values: [String: TemplateValue]
    public let compiled: CompiledPrompt
}

public struct TemplateEngine: Sendable {
    public let templates: [StudioTemplate]
    public init(templates: [StudioTemplate]? = nil) throws {
        if let templates { self.templates = templates }
        else {
            let resources: Bundle
            if Bundle.main.bundleURL.pathExtension == "app" {
                // SwiftPM's generated accessor checks the app root, which codesign cannot seal.
                // Packaged apps use the same SwiftPM bundle in the standard Resources location.
                guard let url = Bundle.main.url(forResource: "QwenAudioStudioMac_StudioCore", withExtension: "bundle"),
                      let packaged = Bundle(url: url) else { throw TemplateError.invalid("应用内缺少模板资源，请重新安装完整应用。") }
                resources = packaged
            } else { resources = Bundle.module }
            guard let url = resources.url(forResource: "templates", withExtension: "json") else { throw TemplateError.missing }
            self.templates = try JSONDecoder().decode([StudioTemplate].self, from: Data(contentsOf: url))
        }
        guard Set(self.templates.map(\.id)).count == self.templates.count else { throw TemplateError.invalid("模板 ID 不可重复。") }
        for item in self.templates { try Self.validate(item) }
    }
    public func preview(templateID: String, values: [String: TemplateValue], bindings: [ReferenceBinding] = []) throws -> TemplatePreview {
        guard let item = templates.first(where: { $0.id == templateID }) else { throw TemplateError.missing }
        let (prompt, resolved) = try Self.expand(item, values: values)
        return TemplatePreview(templateID: item.id, name: item.name, mode: item.mode, prompt: prompt, values: resolved,
            compiled: try PromptCompiler.compile(mode: item.mode, prompt: prompt, bindings: bindings))
    }

    private static let tokenPattern = #"\{\{\s*([A-Za-z][A-Za-z0-9_]{0,39})\s*\}\}"#
    private static func sensitive(_ value: String) -> Bool {
        value.range(of: #"\bsk-[A-Za-z0-9_-]{16,}|data:audio/[^\s]*|\bllm-[a-z0-9]{8,}|Authorization\s*:\s*Bearer\s+\S+"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }
    public static func validate(_ item: StudioTemplate) throws {
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw TemplateError.invalid(message) } }
        try require(!item.id.isEmpty && ["user", "builtin"].contains(item.source), "模板标识无效。")
        try require(!item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && item.name.unicodeScalars.count <= 80, "模板名称需要 1–80 字。")
        try require(item.description.unicodeScalars.count <= 300, "模板说明最多 300 字。")
        try require(!item.promptPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && item.promptPattern.unicodeScalars.count <= 3000, "模板正文需要 1–3000 字。")
        try require(item.tags.count <= 12 && item.tags.allSatisfy { $0.unicodeScalars.count <= 30 }, "最多 12 个标签，每个最多 30 字。")
        try require((0...3).contains(item.roleCount), "角色数必须为 0–3。")
        try require(item.suggestedDurationSeconds.map { (1...600).contains($0) } ?? true, "建议时长必须为 1–600 秒。")
        try require(item.variables.count <= 20 && Set(item.variables.map(\.key)).count == item.variables.count, "变量最多 20 个，名称不可重复。")
        for variable in item.variables {
            try require(variable.key.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,39}$"#, options: .regularExpression) != nil, "变量名称仅支持英文字母开头的字母、数字和下划线。")
            try require(variable.label.unicodeScalars.count <= 80, "变量标签最多 80 字。")
            try require((1...1000).contains(variable.maxLength ?? 200), "变量长度限制必须为 1–1000 字。")
            try require(variable.min?.isFinite ?? true, "数字下限必须为有限数字。")
            try require(variable.max?.isFinite ?? true, "数字上限必须为有限数字。")
            try require((variable.min ?? -.infinity) <= (variable.max ?? .infinity), "数字下限不能大于上限。")
            if variable.type == .select {
                let options = variable.options ?? []
                try require((1...30).contains(options.count) && options.allSatisfy { !$0.isEmpty && $0.unicodeScalars.count <= 100 }, "选项需要 1–30 个有效文本，每个最多 100 字。")
            }
        }
        let strings = [item.id, item.name, item.description, item.promptPattern] + item.tags + item.variables.flatMap {
            [$0.key, $0.label, $0.defaultValue.display] + ($0.options ?? [])
        }
        try require(!strings.contains(where: sensitive), "模板不能保存 API Key、业务空间标识或音频数据。")
        let regex = try NSRegularExpression(pattern: tokenPattern)
        let range = NSRange(item.promptPattern.startIndex..., in: item.promptPattern)
        let matches = regex.matches(in: item.promptPattern, range: range)
        let keys = Set(matches.map { (item.promptPattern as NSString).substring(with: $0.range(at: 1)) })
        let remainder = regex.stringByReplacingMatches(in: item.promptPattern, range: range, withTemplate: "")
        try require(keys == Set(item.variables.map(\.key)) && !remainder.contains("{{") && !remainder.contains("}}"), "正文占位符与变量定义必须一致；仅支持 {{变量名}}。")
        let (prompt, _) = try expand(item, values: [:])
        // Validate reference syntax and length without storing invented audio bindings.
        let voices = try NSRegularExpression(pattern: "@voice([1-3])")
        let slots = voices.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)).compactMap {
            Int((prompt as NSString).substring(with: $0.range(at: 1)))
        }
        let validationBindings = (0..<(slots.max() ?? 0)).map { ReferenceBinding(referenceID: "validation-\($0)", alias: "", slot: $0 + 1) }
        _ = try PromptCompiler.compile(mode: item.mode, prompt: prompt, bindings: validationBindings)
    }

    private static func expand(_ item: StudioTemplate, values: [String: TemplateValue]) throws -> (String, [String: TemplateValue]) {
        guard Set(values.keys).isSubset(of: Set(item.variables.map(\.key))) else { throw TemplateError.invalid("填写了模板中未定义的变量。") }
        var resolved: [String: TemplateValue] = [:]
        for variable in item.variables {
            let value = values[variable.key] ?? variable.defaultValue
            let invalid = TemplateError.invalid("请为“\(variable.label)”填写有效的\(variable.type == .number ? "范围内数字" : "文本或选项")。")
            switch (variable.type, value) {
            case (.number, .number(let number)):
                guard number.isFinite, number >= (variable.min ?? -.infinity), number <= (variable.max ?? .infinity) else { throw invalid }
            case (.text, .text(let text)), (.select, .text(let text)):
                guard text.unicodeScalars.count <= (variable.maxLength ?? 200),
                      !variable.required || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      variable.type != .select || (variable.options ?? []).contains(text) else { throw invalid }
                guard !text.contains("{{"), !text.contains("}}"), !sensitive(text) else { throw TemplateError.invalid("变量不能包含模板表达式或敏感内容。") }
            default: throw invalid
            }
            resolved[variable.key] = value
        }
        let regex = try NSRegularExpression(pattern: tokenPattern)
        var result = item.promptPattern
        // Reverse replacement treats values literally, including dollar signs and backslashes.
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            let key = (item.promptPattern as NSString).substring(with: match.range(at: 1))
            guard let replacement = resolved[key], let range = Range(match.range, in: result) else { throw TemplateError.invalid("存在未解析的模板表达式。") }
            result.replaceSubrange(range, with: replacement.display)
        }
        return (result, resolved)
    }
}

public protocol TemplateStore: Sendable {
    func list() async throws -> [StudioTemplate]
    func favorites() async throws -> Set<String>
    func save(_ template: StudioTemplate) async throws
    func remove(id: String) async throws
    func setFavorite(id: String, favorite: Bool) async throws
}

public actor InMemoryTemplateStore: TemplateStore {
    private var items: [StudioTemplate]
    private var favoriteIDs: Set<String> = []
    public init() throws { items = try TemplateEngine().templates }
    public func list() throws -> [StudioTemplate] { items }
    public func favorites() throws -> Set<String> { favoriteIDs }
    public func save(_ template: StudioTemplate) throws {
        guard !template.isBuiltin, !items.contains(where: { $0.id == template.id && $0.isBuiltin }) else { throw TemplateError.readOnly }
        try TemplateEngine.validate(template)
        if let index = items.firstIndex(where: { $0.id == template.id }) { items[index] = template }
        else { items.append(template) }
    }
    public func remove(id: String) throws {
        guard let item = items.first(where: { $0.id == id }) else { throw TemplateError.missing }
        guard !item.isBuiltin else { throw TemplateError.readOnly }
        items.removeAll { $0.id == id }; favoriteIDs.remove(id)
    }
    public func setFavorite(id: String, favorite: Bool) throws {
        guard items.contains(where: { $0.id == id }) else { throw TemplateError.missing }
        if favorite { favoriteIDs.insert(id) } else { favoriteIDs.remove(id) }
    }
}

@MainActor public final class TemplateApplicationController {
    public let draft: DraftController
    public let undoManager = UndoManager()
    public init(draft: DraftController) {
        self.draft = draft
        // Native editor delegate brackets text changes; templates form a separate transaction.
        undoManager.groupsByEvent = false
    }
    public func apply(_ preview: TemplatePreview) {
        var updated = draft.fields
        updated.name = preview.name; updated.mode = preview.mode; updated.prompt = preview.prompt
        undoManager.beginUndoGrouping()
        replace(with: updated)
        undoManager.setActionName("应用模板")
        undoManager.endUndoGrouping()
    }
    private func replace(with fields: DraftFields) {
        let previous = draft.fields
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.replace(with: previous) }
        }
        draft.replaceFields(fields)
    }
}
