import AppKit
import SwiftUI
import ServiceManagement
import ThoughtCore

struct ChatTurn: Identifiable {
    let id = UUID()
    let question: String
    let date = Date()
    var answer: ChatAnswer?
    var error: String?
}

enum SpeechSource: String, CaseIterable, Identifiable {
    case apple, gemini
    var id: String { rawValue }
    var title: String { self == .apple ? "Apple 語音辨識" : "Google Gemini（AI Studio 金鑰）" }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var recording = false
    @Published var starting = false
    @Published var processing = false
    @Published var summarizing = false
    @Published var seconds: Double = 0
    @Published var clips: [Clip] = []
    @Published var message = "準備好接住你的下一個想法"
    @Published var errorMessage: String?
    @Published var hasKey = false
    @Published var provider = LLMProvider(rawValue: UserDefaults.standard.string(forKey: "llmProvider") ?? "") ?? .codex
    @Published var cliModel = ""
    @Published var checkingConnection = false
    @Published var connectionMessage: String?
    @Published var modelName = UserDefaults.standard.string(forKey: "model") ?? "gpt-4o-mini"
    @Published var localOnly = UserDefaults.standard.object(forKey: "localOnly") as? Bool ?? true
    @Published var speechSource = SpeechSource(rawValue: UserDefaults.standard.string(forKey: "speechSource") ?? "") ?? .apple
    @Published var geminiModel = UserDefaults.standard.string(forKey: "geminiModel") ?? GeminiTranscriber.defaultModel
    @Published var hasGeminiKey = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var chat: [ChatTurn] = []
    @Published var asking = false
    @Published var showingChat = false
    private var chatID = AppModel.newChatID()
    private var chatStarted = Date()
    @Published var lastReportDay: String?
    @Published var shortcutAvailable = true
    private(set) var archive: Archive?
    private var apiKey = ""
    private var geminiKey = ""
    private let audio = AudioCapture()
    private var current: Clip?
    private var queue: [String] = []
    private var revisions: [String: String] = [:]
    private var attempts: [String: Date] = [:]
    private var timer: Timer?
    private var elapsedTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    let vault = VaultLocation.defaultVault
    let root = VaultLocation.defaultRoot
    var llmAvailable: Bool { provider == .openAI ? hasKey : CLITransport.executable(for: provider) != nil }
    private var client: LLMClient { LLMClient(apiKey: apiKey, model: provider == .openAI ? modelName : cliModel, provider: provider) }

    var todayCount: Int { clips.filter { $0.day == Day.key(Date()) }.count }
    var pendingCount: Int { clips.filter { $0.status != .complete && $0.status != .recording }.count }

    func showChat() {
        showingChat = true
    }

    func dismissChat() {
        showingChat = false
    }

    init() {
        do {
            let legacy = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ThoughtDrop")
            _ = try VaultLocation.prepare(vault: vault, legacy: legacy)
            let store = try Archive(root: root, vault: vault)
            archive = store
            clips = try store.loadClips()
            for index in clips.indices where clips[index].status == .recording {
                clips[index].status = .recorded
                clips[index].error = "上次錄音未正常結束，將嘗試從已保存的音檔復原。"
                try store.save(clips[index])
            }
            try store.regenerateDocuments()
            let reports = try store.reports()
            revisions = Dictionary(uniqueKeysWithValues: reports.map { ($0.day, $0.revision) })
            lastReportDay = reports.last?.day
            cliModel = UserDefaults.standard.string(forKey: provider.rawValue + "Model") ?? ""
            if provider == .openAI {
                apiKey = try Keychain.read()
                hasKey = !apiKey.isEmpty
            }
            geminiKey = try Keychain.read(service: Keychain.gemini)
            hasGeminiKey = !geminiKey.isEmpty
        } catch { errorMessage = error.localizedDescription }
        audio.didFinish = { [weak self] duration, error in self?.finishRecording(duration: duration, error: error) }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkSchedule() }
        }
        timer?.tolerance = 3
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.checkSchedule() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.recording == true { self?.audio.stop() } }
        })
        Task {
            for clip in clips where clip.status == .recorded || (clip.status == .transcribed && llmAvailable) { enqueue(clip.id) }
            await checkSchedule()
        }
    }

    func toggleRecording() {
        guard !starting else { return }
        if recording { audio.stop(); return }
        guard let archive else { errorMessage = "無法開啟儲存資料夾，請檢查 \(root.path) 的權限並重新啟動。"; return }
        starting = true
        errorMessage = nil
        Task { [self] in
            var clip = Clip()
            do {
                try archive.save(clip)
                current = clip
                try await audio.start(at: archive.audio(clip))
                clips.append(clip)
                recording = true
                seconds = 0
                message = "正在聽，慢慢說"
                elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.seconds = self?.audio.duration ?? 0 }
                }
            } catch {
                clip.status = .failed
                clip.error = error.localizedDescription
                do { try archive.save(clip) } catch { errorMessage = "無法保存錄音狀態：\(error.localizedDescription)" }
                clips.append(clip)
                current = nil
                errorMessage = clip.error
            }
            starting = false
        }
    }

    private func finishRecording(duration: Double, error: String?) {
        guard var clip = current, let archive else { return }
        current = nil
        recording = false
        elapsedTimer?.invalidate(); elapsedTimer = nil
        if error == nil, Clip.isTooShort(duration) {
            do {
                try archive.discard(clip)
                clips.removeAll { $0.id == clip.id }
                message = "錄音少於 \(Int(Clip.minimumDuration)) 秒，已略過（檔案在垃圾桶）"
            } catch { errorMessage = "錄音過短但無法移除：\(error.localizedDescription)" }
            return
        }
        clip.duration = duration
        clip.status = .recorded
        clip.error = error
        do {
            try archive.save(clip)
            replace(clip)
            message = "錄音已保存，正在整理文字"
            if let error { errorMessage = error }
            enqueue(clip.id)
        } catch { errorMessage = "音檔已保留，但索引更新失敗：\(error.localizedDescription)" }
    }

    func retryPending() {
        errorMessage = nil
        for clip in clips where clip.status != .complete && clip.status != .recording { enqueue(clip.id) }
    }

    private func enqueue(_ id: String) {
        if !queue.contains(id) { queue.append(id) }
        guard !processing else { return }
        processing = true
        Task { await processQueue() }
    }

    private func processQueue() async {
        defer { processing = false }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard var clip = clips.first(where: { $0.id == id }), let archive else { continue }
            do {
                if clip.raw.isEmpty {
                    guard FileManager.default.fileExists(atPath: archive.audio(clip).path) else {
                        throw ThoughtError.message("找不到這筆錄音的音檔，請檢查麥克風權限後重新錄製。")
                    }
                    if speechSource == .gemini {
                        clip.raw = try await GeminiTranscriber(apiKey: geminiKey, model: geminiModel).transcribe(audioAt: archive.audio(clip))
                    } else {
                        clip.raw = try await audio.transcribe(url: archive.audio(clip), localOnly: localOnly)
                    }
                    clip.status = .transcribed
                    clip.error = nil
                    try archive.save(clip)
                    replace(clip)
                }
                if llmAvailable {
                    clip.corrected = try await client.correct(clip.raw)
                    clip.status = .complete
                    clip.error = nil
                    try archive.save(clip)
                    message = "已接住你的想法"
                } else {
                    message = "逐字稿已保存；請在設定完成 LLM 連線"
                }
                replace(clip)
            } catch {
                clip.status = .failed
                clip.error = error.localizedDescription
                do { try archive.save(clip) }
                catch { errorMessage = "音檔已保留，但儲存狀態失敗：\(error.localizedDescription)" }
                replace(clip)
                errorMessage = clip.error
                message = "原始資料已保存，可從選單重試"
            }
        }
    }

    private func replace(_ clip: Clip) {
        if let index = clips.firstIndex(where: { $0.id == clip.id }) { clips[index] = clip }
    }

    func saveSettings(provider: LLMProvider, key: String, model: String, local: Bool, login: Bool,
                      speech: SpeechSource = .apple, geminiKey newGeminiKey: String = "", geminiModel newGeminiModel: String = "") throws {
        guard !processing, !summarizing, !checkingConnection, !asking else { throw ThoughtError.message("請等目前 LLM 工作完成後再變更設定。") }
        guard provider != .openAI || !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ThoughtError.message("請填入 API 模型名稱。") }
        if login != launchAtLogin {
            if login { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        // Empty input keeps an existing key; deletion is a separate, explicit button.
        if provider == .openAI && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let trimmedGemini = newGeminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGemini.isEmpty { try Keychain.save(trimmedGemini, service: Keychain.gemini) }
        geminiKey = try Keychain.read(service: Keychain.gemini)
        hasGeminiKey = !geminiKey.isEmpty
        guard speech != .gemini || hasGeminiKey else { throw ThoughtError.message("使用 Gemini 辨識前，請先填入 Google AI Studio 金鑰。") }
        speechSource = speech
        geminiModel = newGeminiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? GeminiTranscriber.defaultModel : newGeminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(speech.rawValue, forKey: "speechSource")
        UserDefaults.standard.set(geminiModel, forKey: "geminiModel")
        if provider == .openAI { apiKey = try Keychain.read() }
        hasKey = !apiKey.isEmpty
        self.provider = provider
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .openAI { modelName = name } else { cliModel = name }
        localOnly = local
        UserDefaults.standard.set(provider.rawValue, forKey: "llmProvider")
        UserDefaults.standard.set(name, forKey: provider.rawValue + "Model")
        UserDefaults.standard.set(modelName, forKey: "model")
        UserDefaults.standard.set(local, forKey: "localOnly")
        attempts.removeAll()
        retryPending()
    }

    func removeGeminiKey() throws {
        try Keychain.save("", service: Keychain.gemini)
        geminiKey = ""; hasGeminiKey = false
        speechSource = .apple
        UserDefaults.standard.set(SpeechSource.apple.rawValue, forKey: "speechSource")
    }

    func removeKey() throws {
        try Keychain.save("")
        apiKey = ""; hasKey = false
    }

    func checkSchedule() async {
        guard !recording, !starting, !processing, !summarizing, !checkingConnection, llmAvailable else { return }
        let grouped = Dictionary(grouping: clips, by: \.day)
        let now = Date()
        for day in grouped.keys.sorted() {
            let entries = grouped[day]!
            guard Day.isDue(day, now: now), entries.contains(where: { !$0.text.isEmpty }),
                  revisions[day] != Day.fingerprint(entries),
                  attempts[day].map({ now.timeIntervalSince($0) >= 900 }) ?? true else { continue }
            await summarize(day: day)
            break
        }
    }

    func summarizeToday() { Task { await summarize(day: Day.key(Date())) } }

    private func summarize(day: String) async {
        guard !summarizing, !processing, !recording, !starting, let archive else { return }
        guard llmAvailable else { errorMessage = "請先在設定中完成 LLM 連線。"; return }
        let snapshot = clips.filter { $0.day == day && $0.status != .recording }
        guard snapshot.contains(where: { !$0.text.isEmpty }) else { errorMessage = "這一天還沒有可整理的逐字稿。"; return }
        summarizing = true
        attempts[day] = Date()
        defer { summarizing = false }
        do {
            let titles = Array(Set(try archive.reports().flatMap { $0.report.notes.map(\.title) })).sorted()
            let report = try await client.summarize(day: day, clips: snapshot, existingTitles: titles)
            try archive.persistReport(report, day: day, clips: snapshot)
            revisions[day] = Day.fingerprint(snapshot)
            lastReportDay = day
            attempts[day] = nil
            message = "\(day) 的回顧與知識庫已更新"
        } catch { errorMessage = "\(day) 整理未完成：\(error.localizedDescription)" }
    }

    private static func newChatID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    func newChat() {
        guard !asking else { return }
        chat = []; chatID = Self.newChatID(); chatStarted = Date()
    }

    func openSource(_ passage: Passage) { openNote(root.appendingPathComponent(passage.path)) }

    func ask(_ question: String) {
        guard !asking, let archive else { return }
        let turn = ChatTurn(question: question)
        let history = chat.compactMap { previous in previous.answer.map { (question: previous.question, answer: $0.text) } }
        let query = [chat.last?.question, question].compactMap { $0 }.joined(separator: " ")
        chat.append(turn)
        guard llmAvailable else { finishAsk(turn.id) { $0.error = "尚未完成 LLM 連線，請先在設定登入 \(provider.title)。" }; return }
        asking = true
        let retriever = WikiRetriever(root: root), client = client
        Task {
            do {
                let passages = try await Task.detached { try retriever.search(query) }.value
                let answer = passages.isEmpty
                    ? ChatAnswer(text: "wiki 裡找不到和這個問題相關的內容，所以不回答，以免憑空編造。可以換個說法，或先多錄幾則相關想法。", sources: [])
                    : try await client.answer(question: question, history: history, passages: passages)
                finishAsk(turn.id) { $0.answer = answer }
                let turns = chat.compactMap { t in t.answer.map { (question: t.question, answer: $0, date: t.date) } }
                do { try archive.saveChat(id: chatID, started: chatStarted, turns: turns) }
                catch { errorMessage = "回答已顯示，但對話存檔失敗：\(error.localizedDescription)" }
            } catch { finishAsk(turn.id) { $0.error = error.localizedDescription } }
            asking = false
        }
    }

    private func finishAsk(_ id: UUID, _ change: (inout ChatTurn) -> Void) {
        if let index = chat.firstIndex(where: { $0.id == id }) { change(&chat[index]) }
    }

    func openFolder() { NSWorkspace.shared.open(root) }
    func openWiki() { openNote(root.appendingPathComponent("wiki/generated/index.md")) }
    func openReview() {
        if let day = lastReportDay { openNote(root.appendingPathComponent("days/\(day)/一日回顧.md")) }
        else { openFolder() }
    }
    private func openNote(_ file: URL) {
        if let url = VaultLocation.openURL(vault: vault, file: file), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(file)
    }
    func checkConnection() {
        guard !checkingConnection, !processing, !summarizing else { return }
        checkingConnection = true
        connectionMessage = "正在測試 \(provider.title)…"
        Task {
            defer { checkingConnection = false }
            do {
                _ = try await client.correct("這是一筆連線測試。")
                connectionMessage = "\(provider.title) 連線成功。"
            } catch { connectionMessage = error.localizedDescription }
        }
    }
}
