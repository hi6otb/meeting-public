import SwiftUI
import PDFKit
import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var selection: UUID?
    @Published var recording = false
    @Published var preparing = false
    @Published var stopping = false
    @Published var status = ""
    @Published private(set) var generatingTitleIDs: Set<UUID> = []
    @Published var error: String?
    @Published var drafts: [Speaker: String] = [:]
    @Published var levels: [Speaker: Double] = [:]
    @Published var busy = false
    @Published var compacting = false
    @Published var assistantDraft = ""
    @Published var draft = ""
    @Published var showSettings = false
    @Published var settingsTab = 0
    @Published var settingsTemplateID: UUID?
    @Published var settingsTemplateSection = 0
    @Published private(set) var templateQuickPhrases = TemplateQuickPhraseLibraries()
    var quickPhraseLibrary: QuickPhraseLibrary { quickPhrases(for: selectedTemplate.id) }
    func quickPhrases(for templateID: UUID) -> QuickPhraseLibrary {
        templateQuickPhrases.byTemplate[templateID.uuidString] ?? QuickPhraseLibrary(phrases: [])
    }
    func openQuickPhraseSettings() {
        settingsTemplateID = selectedTemplate.id; settingsTemplateSection = 1
        settingsTab = 1; showSettings = true
    }
    private var quickPhrasesWritable = true
    @Published var referenceTab = "notes"
    @Published private(set) var templateLibrary = TemplateLibrary()
    @Published private(set) var applyingTemplate = false
    // Start off on every launch, independent of old preferences.
    @Published var autoCoach = false {
        didSet { if !autoCoach { autoTask?.cancel(); needsAdvice = false } }
    }
    @Published var model = UserDefaults.standard.string(forKey: "model") ?? "" {
        didSet { UserDefaults.standard.set(model, forKey: "model") }
    }
    @Published var effort = UserDefaults.standard.string(forKey: "reasoningEffort") ?? "" {
        didSet { UserDefaults.standard.set(effort, forKey: "reasoningEffort") }
    }
    @Published var locale = UserDefaults.standard.string(forKey: "locale") ?? "ja-JP" {
        didSet { UserDefaults.standard.set(locale, forKey: "locale") }
    }
    @Published var microphoneID = UserDefaults.standard.string(forKey: "microphoneID") ?? "" {
        didSet { UserDefaults.standard.set(microphoneID, forKey: "microphoneID") }
    }
    @Published var applicationID = UserDefaults.standard.string(forKey: "applicationID") ?? "" {
        didSet { UserDefaults.standard.set(applicationID, forKey: "applicationID") }
    }
    @Published var pauseSeconds = UserDefaults.standard.object(forKey: "pauseSeconds") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(pauseSeconds, forKey: "pauseSeconds") }
    }
    let codex = CodexClient()
    private(set) var store: SessionStore?
    private var saveEnabled = true
    private let titleGenerator: ([Message]) async throws -> String?
    private(set) var titleTasks: [UUID: Task<Void, Never>] = [:]
    private var titleGenerations: [UUID: UUID] = [:]
    private var shuttingDown = false
    private let capture = AudioCapture()
    private var assemblers: [Speaker: TranscriptAssembler] = [:]
    private var lastVoice: [Speaker: Date] = [:]
    private var lastResult: [Speaker: Date] = [:]
    private var finalizeRequested: Set<Speaker> = []
    private var timer: Timer?
    private var captureGeneration = UUID()
    private var adviceTask: Task<Void, Never>?
    private var adviceGeneration = UUID()
    private var activeSession: UUID?
    private var activeThread: String?
    private var activeTurn: String?
    private var activeMessageID = UUID()
    private var terminalTurns: Set<String> = []
    private var saveTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?
    private var needsAdvice = false
    private var lastAdvice = Date.distantPast
    private var compactionWatchdog: Task<Void, Never>?
    private var compactionUsageReceived = false
    private var contextRestoreTask: Task<Void, Never>?
    private var templateTask: Task<Void, Never>?
    private var needsTemplateSync = false
    private var forceTemplateSync = false
    private var templatesWritable = true
    private var liveMessageIDs: [Speaker: UUID] = [:]
    private var recordingEpoch: Date?
    private var liveSaveTask: Task<Void, Never>?
    var session: Session? { sessions.first { $0.id == selection } }
    var locked: Bool { recording || preparing || stopping || busy || applyingTemplate }
    var selectedTemplate: PromptTemplate {
        templateLibrary.templates.first { $0.id == session?.selectedTemplateID } ?? templateLibrary.defaultTemplate
    }
    var resolvedModelID: String {
        session?.selectedModel ?? (model.isEmpty ? (codex.configuredModel ?? codex.models.first(where: \.isDefault)?.id ?? "") : model)
    }
    var selectedModel: CodexClient.Model? { codex.models.first { $0.id == resolvedModelID } }
    var resolvedEffort: String {
        if let saved = session?.reasoningEffort { return saved }
        if !effort.isEmpty, selectedModel?.efforts.contains(where: { $0.id == effort }) == true { return effort }
        if session?.selectedModel == nil, model.isEmpty, let configured = codex.configuredEffort,
           selectedModel?.efforts.contains(where: { $0.id == configured }) == true { return configured }
        return selectedModel?.defaultEffort ?? ""
    }
    var modelLabel: String { selectedModel?.label ?? (resolvedModelID.isEmpty ? "接続中…" : resolvedModelID) }

    func selectModel(_ value: CodexClient.Model, effort: String) {
        guard !busy, !applyingTemplate, value.efforts.contains(where: { $0.id == effort }) else { return }
        model = value.id
        self.effort = effort
        updateSession {
            $0.selectedModel = value.id; $0.reasoningEffort = effort
        }
    }

    private func validatedSelection() throws -> (model: String, effort: String) {
        guard let selectedModel, selectedModel.efforts.contains(where: { $0.id == resolvedEffort }) else {
            throw AppFailure("利用可能なモデルとeffortを入力欄から選択してください。")
        }
        return (selectedModel.id, resolvedEffort)
    }

    init(root: URL? = nil, titleGenerator: @escaping ([Message]) async throws -> String? = LocalTitleGenerator.generate) {
        self.titleGenerator = titleGenerator
        do { let store = try SessionStore(root: root); self.store = store; sessions = try store.load() }
        catch { saveEnabled = false; self.error = "保存済み履歴を読み込めません。元のファイルは保持しています。\n\(error.localizedDescription)" }
        do { templateLibrary = try store?.loadTemplates() ?? TemplateLibrary() }
        catch { templatesWritable = false; self.error = "テンプレートを読み込めません：\(error.localizedDescription)" }
        do {
            guard templatesWritable else { throw AppFailure("テンプレートを読み込めないため、定型文の移行を中止しました。") }
            templateQuickPhrases = try store?.loadTemplateQuickPhrases(templates: templateLibrary.templates) ?? TemplateQuickPhraseLibraries()
            for key in Array(templateQuickPhrases.byTemplate.keys) {
                var library = templateQuickPhrases.byTemplate[key]!
                if library.defaultID == nil { library.defaultID = library.defaultPhrase?.id }
                library.selectedID = library.defaultPhrase?.id
                templateQuickPhrases.byTemplate[key] = library
            }
        }
        catch { quickPhrasesWritable = false; self.error = "定型文を読み込めません：\(error.localizedDescription)" }
        if !sessions.contains(where: { $0.isArchived != true }) { sessions.insert(Session(selectedTemplateID: templateLibrary.defaultID), at: 0) }
        selection = sessions.first(where: { $0.isArchived != true })?.id
        codex.onEvent = { [weak self] method, params in self?.handleEvent(method, params) }
        codex.onDisconnect = { [weak self] message in
            guard let self else { return }
            if self.busy { self.finishAdvice(failure: message) }
        }
    }

    func connect() async {
        for session in sessions where session.titleGenerationPending == true && titleTasks[session.id] == nil {
            scheduleTitleGeneration(for: session.id)
        }
        guard let root = store?.root else { return }
        do {
            try await codex.connect(cwd: root)
            restoreCurrentContext()
        }
        catch { self.error = error.localizedDescription }
    }
    private func restoreCurrentContext() {
        guard codex.connected, !busy, !applyingTemplate, let snapshot = session, let thread = snapshot.codexThread, let root = store?.root else { return }
        contextRestoreTask?.cancel()
        contextRestoreTask = Task {
            do {
                // Full resume replays the live usage snapshot without starting a turn.
                // Metadata-only resume intentionally does not emit historical usage.
                _ = try await codex.prepareThread(existing: thread, cwd: root, model: "", checkLimits: false)
            } catch {
                if !Task.isCancelled, selection == snapshot.id { self.error = error.localizedDescription }
            }
        }
    }
    func newSession() {
        guard !locked else { return }
        contextRestoreTask?.cancel()
        autoTask?.cancel(); needsAdvice = false; autoCoach = false; referenceTab = "notes"
        let value = Session(selectedTemplateID: templateLibrary.defaultID)
        sessions.insert(value, at: 0); selection = value.id
        save()
    }
    func select(_ id: UUID) {
        guard !locked, sessions.contains(where: { $0.id == id }) else { return }
        contextRestoreTask?.cancel()
        autoTask?.cancel(); needsAdvice = false; autoCoach = false; referenceTab = "notes"
        selection = id; drafts = [:]; assistantDraft = ""
        restoreCurrentContext()
    }
    @discardableResult
    func renameSession(_ id: UUID, title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !locked, !title.isEmpty, let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
        var next = sessions
        next[index].title = title; next[index].hasCustomTitle = true; next[index].titleGenerationPending = false
        guard persistSessionList(next) else { return false }
        cancelTitleGeneration(for: id)
        return true
    }
    func setSessionArchived(_ id: UUID, archived: Bool) {
        guard !locked, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var next = sessions
        next[index].isArchived = archived
        finishSessionRemoval(next, switchSelection: archived && selection == id)
    }
    func deleteSession(_ id: UUID) {
        guard !locked, sessions.contains(where: { $0.id == id }) else { return }
        cancelTitleGeneration(for: id)
        finishSessionRemoval(sessions.filter { $0.id != id }, switchSelection: selection == id)
    }
    private func finishSessionRemoval(_ values: [Session], switchSelection: Bool) {
        var next = values
        if !next.contains(where: { $0.isArchived != true }) {
            next.insert(Session(selectedTemplateID: templateLibrary.defaultID), at: 0)
        }
        guard persistSessionList(next) else { return }
        if switchSelection, let id = next.first(where: { $0.isArchived != true })?.id { select(id) }
    }
    @discardableResult
    private func persistSessionList(_ values: [Session]) -> Bool {
        guard saveEnabled, let store else { return false }
        do { try store.save(values); sessions = values; return true }
        catch { self.error = "履歴を保存できません：\(error.localizedDescription)"; return false }
    }
    func updateSession(_ change: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == selection }) else { return }
        change(&sessions[index]); save()
    }
    func save() {
        guard saveEnabled, let store else { return }
        do { try store.save(sessions) }
        catch { self.error = "履歴を保存できません：\(error.localizedDescription)" }
    }
    func editNotes(_ text: String) {
        guard let index = sessions.firstIndex(where: { $0.id == selection }) else { return }
        sessions[index].notes = text
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .milliseconds(400)); if !Task.isCancelled { save() } }
    }
    func append(_ speaker: Speaker, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateSession {
            if $0.messages.isEmpty && $0.hasCustomTitle != true { $0.title = String(trimmed.prefix(28)) }
            $0.messages.append(Message(speaker: speaker, text: trimmed))
        }
        if speaker == .me || speaker == .partner, autoCoach { queueAdvice() }
    }
    func sendDraft() {
        if sendQuestion(draft) { draft = "" }
    }
    @discardableResult
    private func sendQuestion(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, !applyingTemplate, session != nil, store != nil else { return false }
        updateSession {
            if $0.messages.isEmpty && $0.hasCustomTitle != true { $0.title = String(text.prefix(28)) }
            $0.messages.append(Message(speaker: .me, text: text, isCoachQuestion: true))
        }
        askAdvice(question: text)
        return true
    }
    func sendQuickPhrase(_ phrase: QuickPhrase) {
        guard quickPhraseLibrary.phrases.contains(phrase), sendQuestion(phrase.text) else { return }
        selectQuickPhrase(phrase.id)
    }
    func selectQuickPhrase(_ id: UUID, templateID: UUID? = nil) {
        var library = quickPhrases(for: templateID ?? selectedTemplate.id)
        guard library.phrases.contains(where: { $0.id == id }) else { return }; library.selectedID = id
        persistQuickPhrases(library, templateID: templateID ?? selectedTemplate.id)
    }
    @discardableResult
    func saveQuickPhrase(id: UUID?, text: String, templateID: UUID? = nil) -> UUID? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var library = quickPhrases(for: templateID ?? selectedTemplate.id)
        let phrase = QuickPhrase(id: id ?? UUID(), text: text)
        if let index = library.phrases.firstIndex(where: { $0.id == phrase.id }) { library.phrases[index] = phrase }
        else { library.phrases.append(phrase) }
        if library.defaultID == nil { library.defaultID = library.defaultPhrase?.id }
        return persistQuickPhrases(library, templateID: templateID ?? selectedTemplate.id) ? phrase.id : nil
    }
    func setDefaultQuickPhrase(_ id: UUID, templateID: UUID? = nil) {
        var library = quickPhrases(for: templateID ?? selectedTemplate.id)
        guard library.phrases.contains(where: { $0.id == id }) else { return }
        library.defaultID = id; library.selectedID = id
        persistQuickPhrases(library, templateID: templateID ?? selectedTemplate.id)
    }
    func moveQuickPhrase(_ id: UUID, offset: Int, templateID: UUID? = nil) {
        var library = quickPhrases(for: templateID ?? selectedTemplate.id)
        guard let index = library.phrases.firstIndex(where: { $0.id == id }),
              library.phrases.indices.contains(index + offset) else { return }
        let phrase = library.phrases.remove(at: index)
        library.phrases.insert(phrase, at: index + offset)
        persistQuickPhrases(library, templateID: templateID ?? selectedTemplate.id)
    }
    func deleteQuickPhrase(_ id: UUID, templateID: UUID? = nil) {
        var library = quickPhrases(for: templateID ?? selectedTemplate.id)
        library.phrases.removeAll { $0.id == id }
        if library.defaultID == id { library.defaultID = library.phrases.first?.id }
        if library.selectedID == id { library.selectedID = library.defaultPhrase?.id }
        persistQuickPhrases(library, templateID: templateID ?? selectedTemplate.id)
    }
    @discardableResult
    private func persistQuickPhrases(_ library: QuickPhraseLibrary, templateID: UUID) -> Bool {
        guard quickPhrasesWritable, let store else {
            error = "定型文を保存できません。保存先の読み込み状態を確認してください。"
            return false
        }
        guard templateLibrary.templates.contains(where: { $0.id == templateID }) else { return false }
        var libraries = templateQuickPhrases
        libraries.byTemplate[templateID.uuidString] = library
        do { try store.saveTemplateQuickPhrases(libraries); templateQuickPhrases = libraries; return true }
        catch { self.error = error.localizedDescription; return false }
    }

    func startRecording() async {
        guard !recording, !preparing, !stopping else { return }
        if let id = selection { cancelTitleGeneration(for: id) }
        preparing = true; status = "端末内モデルを準備中…"
        captureGeneration = UUID()
        let generation = captureGeneration
        assemblers = [:]; lastVoice = [:]; lastResult = [:]; finalizeRequested = []; drafts = [:]
        liveMessageIDs = [:]; recordingEpoch = nil
        capture.onResult = { [weak self] speaker, start, end, text, final in
            DispatchQueue.main.async {
                guard let self, self.captureGeneration == generation else { return }
                self.receiveTranscript(speaker, start: start, end: end, text: text, final: final)
            }
        }
        capture.onLevel = { [weak self] speaker, value in
            DispatchQueue.main.async {
                guard let self, self.captureGeneration == generation else { return }
                self.levels[speaker] = min(1, value * 10)
                if value > 0.008 { self.lastVoice[speaker] = Date(); self.finalizeRequested.remove(speaker) }
            }
        }
        capture.onError = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.captureGeneration == generation, !self.stopping else { return }
                self.error = error.localizedDescription
                if self.recording { Task { await self.stopRecording() } }
            }
        }
        do {
            try await capture.start(locale: locale, microphoneID: microphoneID, applicationID: applicationID)
            recordingEpoch = Date()
            recording = true; status = ""
            requestTemplateSync(force: true)
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            self.error = "記録を開始できません：\(error.localizedDescription)"
            status = ""
        }
        preparing = false
    }
    func receiveTranscript(_ speaker: Speaker, start: Double, end: Double, text: String, final: Bool) {
        guard speaker == .me || speaker == .partner else { return }
        var assembler = assemblers[speaker] ?? TranscriptAssembler()
        assembler.receive(start: start, end: end, text: text, final: final)
        assemblers[speaker] = assembler
        guard !assembler.text.isEmpty else { return }
        updateLiveMessage(speaker, text: assembler.text, provisional: true,
                          date: recordingEpoch?.addingTimeInterval(start) ?? Date())
        drafts[speaker] = assembler.text
        lastResult[speaker] = Date()
        if liveSaveTask == nil {
            liveSaveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                save(); liveSaveTask = nil
            }
        }
    }
    private func updateLiveMessage(_ speaker: Speaker, text: String, provisional: Bool, date: Date = Date()) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == selection }) else { return }
        if let id = liveMessageIDs[speaker], let index = sessions[sessionIndex].messages.firstIndex(where: { $0.id == id }) {
            sessions[sessionIndex].messages[index].text = text
            sessions[sessionIndex].messages[index].isProvisional = provisional
        } else {
            let message = Message(speaker: speaker, text: text, date: date, isProvisional: provisional)
            liveMessageIDs[speaker] = message.id
            if sessions[sessionIndex].messages.isEmpty && sessions[sessionIndex].hasCustomTitle != true { sessions[sessionIndex].title = String(text.prefix(28)) }
            sessions[sessionIndex].messages.append(message)
        }
    }
    func finalizeUtterance(_ speaker: Speaker, force: Bool = false) {
        guard var assembler = assemblers[speaker], let text = assembler.commit(force: force) else { return }
        updateLiveMessage(speaker, text: text, provisional: false)
        assemblers[speaker] = assembler
        liveMessageIDs.removeValue(forKey: speaker)
        drafts[speaker] = ""
        finalizeRequested.remove(speaker)
        save()
        if autoCoach { queueAdvice() }
    }
    private func tick() {
        let now = Date()
        for speaker in [Speaker.me, .partner] {
            guard let assembler = assemblers[speaker], !assembler.text.isEmpty else { continue }
            let voiceGap = now.timeIntervalSince(lastVoice[speaker] ?? lastResult[speaker] ?? now)
            let resultGap = now.timeIntervalSince(lastResult[speaker] ?? now)
            guard voiceGap >= pauseSeconds else { continue }
            if assembler.isFinal && resultGap >= 0.2 {
                finalizeUtterance(speaker)
            } else if !finalizeRequested.contains(speaker), resultGap >= 0.3 {
                finalizeRequested.insert(speaker)
                Task { await capture.finalize(speaker) }
            }
        }
    }
    func stopRecording() async {
        guard recording, !stopping else { return }
        let sessionID = selection
        stopping = true; timer?.invalidate(); timer = nil
        await capture.stop()
        // Await queued main-actor results from both analyzer result consumers.
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        for speaker in [Speaker.me, .partner] {
            finalizeUtterance(speaker, force: true)
        }
        captureGeneration = UUID()
        assemblers = [:]; drafts = [:]; levels = [:]
        liveMessageIDs = [:]; recordingEpoch = nil
        liveSaveTask?.cancel(); liveSaveTask = nil
        recording = false; stopping = false; status = ""
        save()
        if let sessionID { scheduleTitleGeneration(for: sessionID) }
    }
    func scheduleTitleGeneration(for sessionID: UUID) {
        cancelTitleGeneration(for: sessionID)
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }), sessions[index].hasCustomTitle != true else { return }
        let messages = LocalTitleGenerator.conversation(sessions[index].messages)
        guard !messages.isEmpty else { return }
        sessions[index].titleGenerationPending = true
        save()
        guard !shuttingDown else { return }
        let generation = UUID()
        titleGenerations[sessionID] = generation
        generatingTitleIDs.insert(sessionID)
        titleTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if titleGenerations[sessionID] == generation {
                    titleTasks[sessionID] = nil; titleGenerations[sessionID] = nil
                    generatingTitleIDs.remove(sessionID)
                }
            }
            do {
                let title = try await titleGenerator(messages)
                try Task.checkCancellation()
                guard titleGenerations[sessionID] == generation,
                      let current = sessions.firstIndex(where: { $0.id == sessionID }),
                      sessions[current].hasCustomTitle != true,
                      LocalTitleGenerator.conversation(sessions[current].messages) == messages else { return }
                if let title { sessions[current].title = try LocalTitleGenerator.cleanTitle(title) }
                sessions[current].titleGenerationPending = false
                save()
            } catch {
                guard !Task.isCancelled, titleGenerations[sessionID] == generation,
                      let current = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
                sessions[current].titleGenerationPending = false
                save()
                self.error = "タイトルを生成できません：\(error.localizedDescription) 現在のタイトルを保持しました。"
            }
        }
    }
    private func cancelTitleGeneration(for id: UUID) {
        titleTasks.removeValue(forKey: id)?.cancel()
        titleGenerations[id] = nil
        generatingTitleIDs.remove(id)
    }
    private func queueAdvice() {
        needsAdvice = true
        guard !busy, !applyingTemplate else { return }
        autoTask?.cancel()
        let id = selection
        let delay = max(2, 12 - Date().timeIntervalSince(lastAdvice))
        autoTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, autoCoach, needsAdvice, !busy, !applyingTemplate, selection == id else { return }
            askAdvice(question: "現在のテンプレートに従って、最新の会話に対応してください。")
        }
    }
    private func askAdvice(question: String) {
        guard !busy, !applyingTemplate, let snapshot = session, let store else { return }
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        autoTask?.cancel(); needsAdvice = false
        busy = true; assistantDraft = ""; activeSession = snapshot.id
        compacting = false
        activeThread = nil; activeTurn = nil; activeMessageID = UUID()
        adviceGeneration = UUID()
        let generation = adviceGeneration
        adviceTask = Task {
            do {
                try await codex.connect(cwd: store.root)
                await contextRestoreTask?.value
                guard generation == adviceGeneration, !Task.isCancelled else { return }
                let choice = try validatedSelection()
                let thread = try await codex.prepareThread(existing: snapshot.codexThread, cwd: store.root, model: choice.model, effort: choice.effort)
                guard generation == adviceGeneration, !Task.isCancelled else { return }
                activeThread = thread
                if let index = sessions.firstIndex(where: { $0.id == snapshot.id }) {
                    sessions[index].codexThread = thread
                    sessions[index].selectedModel = choice.model
                    sessions[index].reasoningEffort = choice.effort
                    save()
                }
                try await applyTemplateIfNeeded(thread: thread, sessionID: snapshot.id)
                try await syncContext(thread: thread, sessionID: snapshot.id)
                let prompt = "同期済みの会話タイムラインと資料を踏まえて、以下に対応してください。\n\n" + question
                lastAdvice = Date()
                let turn = try await codex.startTurn(thread: thread, text: prompt, model: choice.model, effort: choice.effort)
                guard generation == adviceGeneration else { return }
                if !terminalTurns.contains(turn) { activeTurn = turn }
            } catch {
                if generation == adviceGeneration {
                    // A timed-out start may have been accepted remotely; ending the
                    // transport prevents a hidden in-flight turn from overlapping a retry.
                    codex.shutdown()
                    finishAdvice(failure: error.localizedDescription)
                }
            }
        }
    }
    private func syncContext(thread: String, sessionID: UUID) async throws {
        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            var references = sessions[index].references
            for i in references.indices where references[i].isClosed != true && references[i].webURL == nil {
                references[i] = try ReferenceText.restoreFullText(references[i])
            }
            if references != sessions[index].references { sessions[index].references = references; save() }
        }
        guard let snapshot = sessions.first(where: { $0.id == sessionID }) else { return }
        let batches = try ContextSync.batches(session: snapshot, threadID: thread)
        for batch in batches {
            try Task.checkCancellation()
            try await codex.appendContext(thread: thread, text: batch.text)
            // Acknowledge only the exact snapshot accepted by the server. Later
            // recognition revisions remain unsent until the next synchronization.
            guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
            var delivery = sessions[index].deliveryState?.threadID == thread
                ? sessions[index].deliveryState! : ContextDeliveryState(threadID: thread)
            batch.acknowledge(into: &delivery)
            sessions[index].deliveryState = delivery
            save()
        }
    }
    func compactContext() {
        guard !busy, !applyingTemplate, let snapshot = session, let thread = snapshot.codexThread, let store else { return }
        autoTask?.cancel(); needsAdvice = false
        busy = true; compacting = true; assistantDraft = ""
        activeSession = snapshot.id; activeThread = thread; activeTurn = nil
        adviceGeneration = UUID()
        let generation = adviceGeneration
        adviceTask = Task {
            do {
                try await codex.connect(cwd: store.root)
                await contextRestoreTask?.value
                guard generation == adviceGeneration, !Task.isCancelled else { return }
                let choice = try validatedSelection()
                _ = try await codex.prepareThread(existing: thread, cwd: store.root, model: choice.model, effort: choice.effort)
                guard generation == adviceGeneration, !Task.isCancelled else { return }
                compactionUsageReceived = false
                compactionWatchdog = Task {
                    try? await Task.sleep(for: .seconds(120))
                    guard !Task.isCancelled, compacting, generation == adviceGeneration else { return }
                    codex.shutdown()
                    finishAdvice(failure: "圧縮の完了を確認できませんでした。再接続してお試しください。")
                }
                try await codex.compact(thread: thread)
                // The RPC only acknowledges starting. Completion comes from turn/completed.
            } catch {
                if generation == adviceGeneration {
                    codex.shutdown()
                    finishAdvice(failure: error.localizedDescription)
                }
            }
        }
    }
    func stopAdvice() {
        autoTask?.cancel(); needsAdvice = false
        if let activeThread, let activeTurn {
            Task {
                do { try await codex.interrupt(thread: activeThread, turn: activeTurn) }
                catch { self.error = error.localizedDescription; codex.shutdown(); finishAdvice(failure: "応答を中断しました。") }
            }
        } else {
            adviceGeneration = UUID(); adviceTask?.cancel()
            codex.shutdown(); finishAdvice(failure: nil)
        }
    }
    private func handleEvent(_ method: String, _ params: [String: Any]) {
        if method == "thread/tokenUsage/updated", let thread = params["threadId"] as? String,
           let usage = ContextUsage(notification: params),
           let index = sessions.firstIndex(where: { $0.codexThread == thread }) {
            sessions[index].contextUsage = usage
            if compacting, thread == activeThread { compactionUsageReceived = true }
            save()
            return
        }
        guard busy, let thread = params["threadId"] as? String, thread == activeThread else { return }
        if method == "turn/started", let turn = params["turn"] as? [String: Any] { activeTurn = turn["id"] as? String }
        if let turn = params["turnId"] as? String, let activeTurn, turn != activeTurn { return }
        if !compacting, method == "item/agentMessage/delta", let delta = params["delta"] as? String { assistantDraft += delta }
        if !compacting, method == "item/completed", let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage", let text = item["text"] as? String {
            assistantDraft = text
        }
        if method == "turn/completed", let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String {
            guard activeTurn == nil || activeTurn == id else { return }
            terminalTurns.insert(id)
            let status = turn["status"] as? String ?? "failed"
            let detail = (turn["error"] as? [String: Any])?["message"] as? String
            finishAdvice(failure: status == "failed" ? (detail ?? "Codexの応答が失敗しました。") : nil, autoContinue: status == "completed")
        }
        // Error notifications alone are not terminal: wait for turn/completed.
        if method == "error" { status = "Codexの接続を確認中…" }
    }
    private func finishAdvice(failure: String?, autoContinue: Bool = false) {
        compactionWatchdog?.cancel(); compactionWatchdog = nil
        if compacting, autoContinue, !compactionUsageReceived,
           let index = sessions.firstIndex(where: { $0.id == activeSession }) {
            // Don't present the pre-compaction measurement as the new context size.
            sessions[index].contextUsage = nil
            save()
        }
        if !assistantDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let index = sessions.firstIndex(where: { $0.id == activeSession }) {
            sessions[index].messages.append(Message(id: activeMessageID, speaker: .codex, text: assistantDraft))
            save()
        }
        busy = false; compacting = false; assistantDraft = ""; activeSession = nil; activeThread = nil; activeTurn = nil; status = ""
        if let failure { error = failure }
        if needsTemplateSync { requestTemplateSync() }
        if autoContinue, needsAdvice, autoCoach { queueAdvice() }
        else if !autoContinue { autoTask?.cancel(); needsAdvice = false }
    }

    func selectTemplate(_ id: UUID) {
        guard templateLibrary.templates.contains(where: { $0.id == id }), selectedTemplate.id != id else { return }
        updateSession { $0.selectedTemplateID = id }
        if recording || session?.codexThread != nil { requestTemplateSync() }
    }

    func setDefaultTemplate(_ id: UUID) {
        guard templateLibrary.templates.contains(where: { $0.id == id }) else { return }
        // A default change applies to new sessions, not a currently running conversation.
        let activeID = selectedTemplate.id
        if session?.selectedTemplateID == nil { updateSession { $0.selectedTemplateID = activeID } }
        var library = templateLibrary
        library.defaultID = id
        persistTemplates(library)
    }

    @discardableResult
    func saveTemplate(id: UUID?, name: String, prompt: String) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty else { error = "テンプレート名とプロンプトを入力してください。"; return nil }
        var library = templateLibrary
        let template = PromptTemplate(id: id ?? UUID(), name: name, prompt: prompt)
        if let index = library.templates.firstIndex(where: { $0.id == template.id }) { library.templates[index] = template }
        else { library.templates.append(template) }
        guard persistTemplates(library) else { return nil }
        if selectedTemplate.id == template.id, recording || session?.codexThread != nil { requestTemplateSync() }
        return template.id
    }

    @discardableResult
    private func persistTemplates(_ library: TemplateLibrary) -> Bool {
        guard templatesWritable, let store else { error = "テンプレートを保存できません。"; return false }
        do {
            try store.saveTemplates(library)
            templateLibrary = library
            return true
        } catch { self.error = "テンプレートを保存できません：\(error.localizedDescription)"; return false }
    }

    private func requestTemplateSync(force: Bool = false) {
        needsTemplateSync = true
        forceTemplateSync = forceTemplateSync || force
        guard !busy, templateTask == nil, let sessionID = selection, let store else { return }
        applyingTemplate = true
        templateTask = Task {
            do {
                while needsTemplateSync && !Task.isCancelled {
                    needsTemplateSync = false
                    let force = forceTemplateSync
                    forceTemplateSync = false
                    guard selection == sessionID else { break }
                    try await codex.connect(cwd: store.root)
                    await contextRestoreTask?.value
                    guard !Task.isCancelled else { break }
                    let choice = try validatedSelection()
                    let thread = try await codex.prepareThread(existing: session?.codexThread, cwd: store.root,
                                                               model: choice.model, effort: choice.effort, checkLimits: false)
                    guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { break }
                    sessions[index].codexThread = thread
                    save()
                    try await applyTemplateIfNeeded(thread: thread, sessionID: sessionID, force: force)
                }
            } catch { self.error = "テンプレートを適用できません：\(error.localizedDescription)" }
            applyingTemplate = false
            templateTask = nil
            if needsAdvice, autoCoach { queueAdvice() }
        }
    }

    private func applyTemplateIfNeeded(thread: String, sessionID: UUID, force: Bool = false) async throws {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let template = templateLibrary.templates.first { $0.id == sessions[index].selectedTemplateID } ?? templateLibrary.defaultTemplate
        let previous = sessions[index].appliedTemplate
        guard force || previous != template else { return }
        try await codex.applyTemplate(thread: thread, template: template)
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if sessions[index].selectedTemplateID == nil { sessions[index].selectedTemplateID = template.id }
        sessions[index].appliedTemplate = template
        let notice = previous == nil || previous == template
            ? "テンプレート「\(template.name)」を適用しました。"
            : "テンプレートを「\(template.name)」に変更しました。"
        sessions[index].messages.append(Message(speaker: .system, text: notice))
        save()
    }

    func closeReference(_ id: UUID) {
        let references = session?.openReferences ?? []
        if referenceTab == id.uuidString, let index = references.firstIndex(where: { $0.id == id }) {
            referenceTab = index > 0 ? references[index - 1].id.uuidString : "notes"
        }
        updateSession { session in
            if let index = session.references.firstIndex(where: { $0.id == id }) { session.references[index].isClosed = true }
        }
    }

    func importReferences() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .plainText, .image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, let store else { return }
        do {
            var imported: [Reference] = []
            for url in panel.urls {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size < 50 * 1024 * 1024 else { throw AppFailure("資料は1ファイル50MBまでです。") }
                let copy = try store.importFile(url)
                let text = try ReferenceText.extract(from: copy)
                imported.append(Reference(name: url.lastPathComponent, path: copy.path, text: text, fullTextAvailable: true))
            }
            updateSession { $0.references += imported }
            if let last = imported.last { referenceTab = last.id.uuidString }
        } catch { self.error = error.localizedDescription }
    }
    func exportTranscript() {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.title.replacingOccurrences(of: "/", with: "-")).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = session.messages.map { "[\($0.date.formatted(date: .omitted, time: .shortened))] \($0.contextLabel)\n\($0.text)" }.joined(separator: "\n\n")
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
    func shutdown() async {
        shuttingDown = true
        for id in Array(titleTasks.keys) { cancelTitleGeneration(for: id) }
        liveSaveTask?.cancel()
        contextRestoreTask?.cancel()
        compactionWatchdog?.cancel()
        autoCoach = false; autoTask?.cancel(); needsAdvice = false
        if recording { await stopRecording() }
        templateTask?.cancel()
        codex.shutdown()
        await templateTask?.value
        save()
    }
}
