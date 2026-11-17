import Foundation

enum Speaker: String, Codable, CaseIterable, Identifiable {
    case me, partner, codex, system
    var id: String { rawValue }
    var label: String { switch self { case .me: "自分"; case .partner: "相手"; case .codex: "Codex"; case .system: "システム" } }
}

struct Message: Identifiable, Codable, Equatable {
    var id = UUID()
    var speaker: Speaker
    var text: String
    var date = Date()
    // Optional for compatibility with saved sessions from the first version.
    var isCoachQuestion: Bool? = nil
    var isProvisional: Bool? = nil
    var isConversation: Bool { (speaker == .me || speaker == .partner) && isCoachQuestion != true }
    var isCoachChat: Bool { speaker == .codex || speaker == .system || isCoachQuestion == true }
    var contextLabel: String { isCoachQuestion == true ? "自分→Codex（手入力）" : speaker.label }
}

struct Reference: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var text: String
    // Retained only to decode old history; legacy link tabs are hidden.
    var webURL: String? = nil
    var isClosed: Bool? = nil
    var fullTextAvailable: Bool? = nil
}

struct QuickPhrase: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
}

struct QuickPhraseLibrary: Codable, Equatable {
    var phrases: [QuickPhrase] = [QuickPhrase(text: "ここまでの会話を要約してください。")]
    var selectedID: UUID? = nil
    var defaultID: UUID? = nil
    var defaultPhrase: QuickPhrase? { phrases.first { $0.id == defaultID } ?? phrases.first }
    var selected: QuickPhrase? { phrases.first { $0.id == selectedID } ?? defaultPhrase }
}

struct TemplateQuickPhraseLibraries: Codable, Equatable {
    var byTemplate: [String: QuickPhraseLibrary] = [:]
}

struct Session: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = "新しいセッション"
    var hasCustomTitle: Bool? = nil
    var titleGenerationPending: Bool? = nil
    var isArchived: Bool? = nil
    var date = Date()
    var messages: [Message] = []
    var notes = ""
    var references: [Reference] = []
    var browserURL = ""
    var codexThread: String?
    var selectedModel: String? = nil
    var reasoningEffort: String? = nil
    var contextUsage: ContextUsage? = nil
    var selectedTemplateID: UUID? = nil
    var appliedTemplate: PromptTemplate? = nil
    var deliveryState: ContextDeliveryState? = nil
    var openReferences: [Reference] { references.filter { $0.isClosed != true && $0.webURL == nil } }
}

struct PromptTemplate: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var prompt: String
    static let standard = PromptTemplate(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, name: "標準", prompt: "会話を聞き、会話の内容を踏まえてユーザーの質問に回答してください。")
}

struct TemplateLibrary: Codable, Equatable {
    var templates: [PromptTemplate] = [.standard]
    var defaultID = PromptTemplate.standard.id
    var defaultTemplate: PromptTemplate { templates.first { $0.id == defaultID } ?? .standard }
}

struct ContextUsage: Codable, Equatable {
    let usedTokens: Int
    let contextWindow: Int?
    var updatedAt = Date()
    var fraction: Double? {
        guard let contextWindow, contextWindow > 0 else { return nil }
        return min(1, max(0, Double(usedTokens) / Double(contextWindow)))
    }
    init?(notification: [String: Any]) {
        guard let usage = notification["tokenUsage"] as? [String: Any],
              let last = usage["last"] as? [String: Any], let tokens = last["totalTokens"] as? Int else { return nil }
        usedTokens = max(0, tokens)
        contextWindow = usage["modelContextWindow"] as? Int
    }
}

enum EffortLabel {
    static func name(_ value: String) -> String {
        switch value {
        case "none": "なし"
        case "minimal": "最小"
        case "low": "低"
        case "medium": "中"
        case "high": "高"
        case "xhigh": "非常に高い"
        case "max": "最大"
        case "ultra": "ウルトラ"
        default: value.isEmpty ? "未取得" : value
        }
    }
}

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Apple revises volatile ranges; replacing overlapping ranges avoids repeated words.
struct TranscriptAssembler {
    struct Piece {
        var start: Double
        var end: Double
        var text: String
        var final: Bool
    }
    private(set) var pieces: [Piece] = []
    private var committedThrough: Double = -.infinity
    var text: String { pieces.sorted { $0.start < $1.start }.map(\.text).joined() }
    var isFinal: Bool { !pieces.isEmpty && pieces.allSatisfy(\.final) }
    mutating func receive(start: Double, end: Double, text: String, final: Bool) {
        guard end > committedThrough + 0.0001, !text.isEmpty else { return }
        pieces.removeAll { abs($0.start - start) < 0.001 || ($0.start < end && $0.end > start) }
        pieces.append(Piece(start: start, end: end, text: text, final: final))
    }
    mutating func commit(force: Bool = false) -> String? {
        guard force || isFinal else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        committedThrough = pieces.map(\.end).max() ?? committedThrough
        pieces.removeAll()
        return value
    }
}

struct SessionStore {
    let root: URL
    init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Interview", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func load() throws -> [Session] {
        let url = root.appendingPathComponent("sessions.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Session].self, from: Data(contentsOf: url))
    }
    func save(_ sessions: [Session]) throws {
        let url = root.appendingPathComponent("sessions.json")
        try JSONEncoder().encode(sessions).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func loadTemplates() throws -> TemplateLibrary {
        let url = root.appendingPathComponent("templates.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return TemplateLibrary() }
        let library = try JSONDecoder().decode(TemplateLibrary.self, from: Data(contentsOf: url))
        guard library.templates.contains(where: { $0.id == library.defaultID }) else { throw AppFailure("既定のテンプレートが見つかりません。") }
        return library
    }
    func saveTemplates(_ library: TemplateLibrary) throws {
        let url = root.appendingPathComponent("templates.json")
        try JSONEncoder().encode(library).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func importFile(_ source: URL) throws -> URL {
        let directory = root.appendingPathComponent("References", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
    func loadQuickPhrases() throws -> QuickPhraseLibrary {
        let url = root.appendingPathComponent("quick-phrases.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return QuickPhraseLibrary() }
        return try JSONDecoder().decode(QuickPhraseLibrary.self, from: Data(contentsOf: url))
    }
    func saveQuickPhrases(_ library: QuickPhraseLibrary) throws {
        let url = root.appendingPathComponent("quick-phrases.json")
        try JSONEncoder().encode(library).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func loadTemplateQuickPhrases(templates: [PromptTemplate]) throws -> TemplateQuickPhraseLibraries {
        let url = root.appendingPathComponent("template-quick-phrases.json")
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(TemplateQuickPhraseLibraries.self, from: Data(contentsOf: url))
        }
        // Old phrases were shared by every template. Copy them once into each
        // existing template, retaining the original file as a migration backup.
        let legacy = try loadQuickPhrases()
        let migrated = TemplateQuickPhraseLibraries(byTemplate: Dictionary(uniqueKeysWithValues: templates.map { ($0.id.uuidString, legacy) }))
        try saveTemplateQuickPhrases(migrated)
        return migrated
    }
    func saveTemplateQuickPhrases(_ libraries: TemplateQuickPhraseLibraries) throws {
        let url = root.appendingPathComponent("template-quick-phrases.json")
        try JSONEncoder().encode(libraries).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
