import Foundation

/// Only the app's main actor writes to this store. No LLM output is used as a path.
public final class Archive {
    public let root: URL
    public let vault: URL?
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }()

    public init(root: URL, vault: URL? = nil) throws {
        self.root = root
        self.vault = vault
        for path in ["days", "wiki/generated/topics", "wiki/personal"] {
            try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let readme = root.appendingPathComponent("wiki/personal/README.md")
        if !fm.fileExists(atPath: readme.path) {
            try "# 自己的筆記\n\n這裡可自由編輯。自動生成的知識與記憶位於 ../generated/，重新整理時會更新。\n".write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    public func folder(_ day: String) -> URL { root.appendingPathComponent("days/\(day)") }
    public func audio(_ clip: Clip) -> URL { folder(clip.day).appendingPathComponent("audio/\(clip.id).m4a") }

    public func save(_ clip: Clip) throws {
        let dir = folder(clip.day)
        for path in ["audio", "transcripts", "metadata"] {
            try fm.createDirectory(at: dir.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        // The JSON is the recovery checkpoint; Markdown is a derived, readable view.
        try encoder.encode(clip).write(to: dir.appendingPathComponent("metadata/\(clip.id).json"), options: .atomic)
        let text = """
        # 語音筆記 · \(clip.date.formatted(date: .abbreviated, time: .standard))

        - ID：\(clip.id)
        - 錄音日期：\(clip.day)
        - 長度：\(Int(clip.duration)) 秒
        - 狀態：\(clip.status.rawValue)
        - \(link("days/\(clip.day)/audio/\(clip.id).m4a", label: "原始錄音", relative: "../audio/\(clip.id).m4a"))

        ## 校正逐字稿

        \(clip.corrected ?? "（尚未完成 LLM 校正；下方保留辨識原文。）")

        ## 辨識原文

        \(clip.raw.isEmpty ? "（等待語音辨識）" : clip.raw)

        \(clip.error.map { "## 處理訊息\n\n\($0)" } ?? "")
        """
        try write(text, to: dir.appendingPathComponent("transcripts/\(clip.id).md"))
    }

    /// Moves a clip's audio, transcript and metadata to the Trash (recoverable). `remove` is injectable for tests.
    public func discard(_ clip: Clip, remove: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        let dir = folder(clip.day)
        for url in [audio(clip), dir.appendingPathComponent("transcripts/\(clip.id).md"), dir.appendingPathComponent("metadata/\(clip.id).json")]
        where fm.fileExists(atPath: url.path) { try remove(url) }
    }

    public func loadClips() throws -> [Clip] {
        var clips: [Clip] = []
        for day in try fm.contentsOfDirectory(at: root.appendingPathComponent("days"), includingPropertiesForKeys: nil) {
            let metadata = day.appendingPathComponent("metadata")
            guard fm.fileExists(atPath: metadata.path) else { continue }
            for file in try fm.contentsOfDirectory(at: metadata, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                do { clips.append(try decoder.decode(Clip.self, from: Data(contentsOf: file))) }
                catch { throw ThoughtError.message("無法讀取筆記索引：\(file.lastPathComponent)。原始檔案未變更。") }
            }
        }
        return clips.sorted { $0.date < $1.date }
    }

    public func reports() throws -> [SavedReport] {
        try fm.contentsOfDirectory(at: root.appendingPathComponent("days"), includingPropertiesForKeys: nil)
            .compactMap { day in
                let url = day.appendingPathComponent("report.json")
                guard fm.fileExists(atPath: url.path) else { return nil }
                return try decoder.decode(SavedReport.self, from: Data(contentsOf: url))
            }.sorted { $0.day < $1.day }
    }

    public func persistReport(_ report: DailyReport, day: String, clips: [Clip]) throws {
        let available = Set(clips.filter { !$0.text.isEmpty }.map(\.id))
        guard !report.review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !report.tomorrow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              report.notes.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  !$0.sources.isEmpty && Set($0.sources).isSubset(of: available) && ["knowledge", "memory"].contains($0.kind) }) else {
            throw ThoughtError.message("整理結果缺少內容或引用來源無效，尚未更新知識庫。")
        }
        let saved = SavedReport(day: day, revision: Day.fingerprint(clips), generatedAt: Date(), report: report, clips: clips)
        try fm.createDirectory(at: folder(day), withIntermediateDirectories: true)
        try encoder.encode(saved).write(to: folder(day).appendingPathComponent("report.json"), options: .atomic)
        try regenerateDocuments()
    }

    /// Idempotent reconstruction after an interrupted write, with dated sources kept intact.
    public func regenerateDocuments() throws {
        let all = try reports()
        var grouped: [String: [(SavedReport, WikiNote)]] = [:]
        for saved in all {
            let sourceLinks = saved.clips.filter { !$0.text.isEmpty }.map {
                "- \(link("days/\(saved.day)/transcripts/\($0.id).md", label: String($0.id.prefix(8)), relative: "transcripts/\($0.id).md"))\($0.corrected == nil ? "（未校正）" : "")"
            }.joined(separator: "\n")
            let missing = saved.clips.filter { $0.text.isEmpty }.count
            let footer = "\n\n---\n更新：\(saved.generatedAt.formatted())\n\n未取得逐字稿：\(missing) 筆。以下內容僅根據已列出的來源。\n\n## 來源\n\n\(sourceLinks)\n"
            try write("# \(saved.day) 一日回顧\n\n\(saved.report.review)\(footer)", to: folder(saved.day).appendingPathComponent("一日回顧.md"))
            try write("# \(saved.day) 明日建議立刻要做的代辦事項\n\n> 以下為建議，並非已承諾的行程。\n\n\(saved.report.tomorrow)\(footer)", to: folder(saved.day).appendingPathComponent("明日代辦.md"))
            for note in saved.report.notes {
                let normalized = note.title.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
                let key = String(Day.digest(normalized).prefix(24))
                grouped[key, default: []].append((saved, note))
            }
        }
        let generated = root.appendingPathComponent("wiki/generated")
        var index = "# 知識與記憶\n\n由錄音整理；想法、推測與偏好不等於客觀事實。請點來源核對。\n\n## 主題\n\n"
        var memories = "# 記憶時間線\n\n只記錄曾明確表達的偏好、決定與狀態，不把單日情緒推定為固定人格。\n\n"
        for key in grouped.keys.sorted() {
            let entries = grouped[key]!
            let title = entries.last!.1.title.replacingOccurrences(of: "\n", with: " ")
            index += "- \(link("wiki/generated/topics/\(key).md", label: title, relative: "topics/\(key).md"))\n"
            var page = "# \(title)\n\n\(link("wiki/generated/index.md", label: "知識庫首頁", relative: "../index.md"))\n\n"
            for (saved, note) in entries {
                let sources = note.sources.map { link("days/\(saved.day)/transcripts/\($0).md", label: String($0.prefix(8)), relative: "../../../days/\(saved.day)/transcripts/\($0).md") }.joined(separator: "、")
                page += "## \(saved.day)\n\n\(note.content)\n\n來源：\(sources)\n\n"
                if note.kind == "memory" {
                    memories += "## \(saved.day) · \(title)\n\n\(note.content)\n\n\(link("wiki/generated/topics/\(key).md", label: "主題與原始來源", relative: "topics/\(key).md"))\n\n"
                }
            }
            try write(page, to: generated.appendingPathComponent("topics/\(key).md"))
        }
        // Remove only obsolete machine-owned topic files after all new pages were written.
        for file in try fm.contentsOfDirectory(at: generated.appendingPathComponent("topics"), includingPropertiesForKeys: nil)
            where file.pathExtension == "md" && !grouped.keys.contains(file.deletingPathExtension().lastPathComponent) {
            try fm.removeItem(at: file)
        }
        index += "\n## 每日回顧\n\n" + all.reversed().map {
            "- \(link("days/\($0.day)/一日回顧.md", label: $0.day, relative: "../../days/\($0.day)/一日回顧.md")) · \(link("days/\($0.day)/明日代辦.md", label: "明日代辦", relative: "../../days/\($0.day)/明日代辦.md"))"
        }.joined(separator: "\n")
        index += "\n\n\(link("wiki/generated/memory.md", label: "記憶時間線", relative: "memory.md")) · \(link("wiki/personal/README.md", label: "自己的筆記", relative: "../personal/README.md"))\n"
        try write(memories, to: generated.appendingPathComponent("memory.md"))
        try write(index, to: generated.appendingPathComponent("index.md"))
    }

    /// Writes one conversation as a Markdown note under `chats/`. These are never indexed for retrieval,
    /// so an answer can never be fed back as if it were a source.
    public func saveChat(id: String, started: Date, turns: [(question: String, answer: ChatAnswer, date: Date)]) throws {
        guard id.allSatisfy({ $0.isNumber || $0 == "-" }) else { throw ThoughtError.message("對話代號無效。") }
        try fm.createDirectory(at: root.appendingPathComponent("chats"), withIntermediateDirectories: true)
        var text = "# 知識庫對話 \(started.formatted(date: .abbreviated, time: .shortened))\n\n> 回答由 LLM 根據 wiki 檢索段落產生，請以來源為準。\n\n"
        for turn in turns {
            text += "## \(turn.question.replacingOccurrences(of: "\n", with: " "))\n\n\(turn.answer.text)\n\n"
            if !turn.answer.sources.isEmpty {
                text += "來源：" + turn.answer.sources.map { source in
                    link(source.path, label: source.title, relative: "../\(source.path)")
                }.joined(separator: "、") + "\n\n"
            }
        }
        try write(text, to: root.appendingPathComponent("chats/\(id).md"))
    }

    private func write(_ text: String, to url: URL) throws {
        let title = String((text.split(separator: "\n").first ?? "拾念").drop(while: { $0 == "#" || $0 == " " }))
        let quoted = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let header = vault == nil ? "" : "---\ntitle: \"\(quoted)\"\ntags: [thoughtdrop]\ngenerated: true\n---\n\n"
        try (header + text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func link(_ path: String, label: String, relative: String) -> String {
        let label = label.replacingOccurrences(of: "]", with: "）").replacingOccurrences(of: "[", with: "（").replacingOccurrences(of: "|", with: "／").replacingOccurrences(of: "\n", with: " ")
        guard let vault, root.path.hasPrefix(vault.path + "/") else { return "[\(label)](\(relative))" }
        let prefix = String(root.path.dropFirst(vault.path.count + 1))
        let target = path.hasSuffix(".md") ? String(path.dropLast(3)) : path
        return "[[\(prefix)/\(target)|\(label)]]"
    }
}
