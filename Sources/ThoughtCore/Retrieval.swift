import Foundation

public struct Passage: Sendable, Equatable {
    public var id = ""
    public let path: String   // relative to the ThoughtDrop root
    public let title: String
    public let text: String
}

/// Local keyword retrieval over the wiki only (generated topics, memory timeline, personal notes).
/// Nothing leaves the Mac here; only the selected passages are later passed to the LLM.
public struct WikiRetriever: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func passages() throws -> [Passage] {
        let fm = FileManager.default
        let base = root.resolvingSymlinksInPath()
        var result: [Passage] = []
        for folder in ["wiki/generated", "wiki/personal"] {
            let start = base.appendingPathComponent(folder)
            guard let items = fm.enumerator(at: start, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) else { continue }
            for case let file as URL in items where file.pathExtension == "md" {
                let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? 0) < 1_000_000 else { continue }
                let resolved = file.resolvingSymlinksInPath().path
                guard resolved.hasPrefix(base.path + "/") else { continue }
                let relative = String(resolved.dropFirst(base.path.count + 1))
                // Navigation-only or placeholder pages carry no knowledge.
                guard relative != "wiki/generated/index.md", relative != "wiki/personal/README.md" else { continue }
                result += Self.sections(of: try String(contentsOf: file, encoding: .utf8), path: relative)
                if result.count > 5000 { return result }
            }
        }
        return result
    }

    public func search(_ query: String, limit: Int = 6) throws -> [Passage] {
        Self.rank(query, in: try passages(), limit: limit)
    }

    static func sections(of markdown: String, path: String) -> [Passage] {
        var lines = markdown.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...end) }
        let fallback = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var docTitle = fallback
        var heading = ""
        var body: [String] = []
        var found: [Passage] = []
        func flush() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            body = []
            guard !text.isEmpty else { return }
            let title = heading.isEmpty ? docTitle : "\(docTitle) › \(heading)"
            var chunk = ""
            for paragraph in text.components(separatedBy: "\n\n") {
                if !chunk.isEmpty, chunk.count + paragraph.count > 800 {
                    found.append(Passage(path: path, title: title, text: chunk)); chunk = ""
                }
                chunk += (chunk.isEmpty ? "" : "\n\n") + paragraph
            }
            if !chunk.isEmpty { found.append(Passage(path: path, title: title, text: chunk)) }
        }
        var sawTitle = false
        for line in lines {
            if line.hasPrefix("# "), !sawTitle { sawTitle = true; docTitle = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("## ") { flush(); heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            else { body.append(line) }
        }
        flush()
        return found
    }

    /// Chinese has no spaces, so CJK runs become character bigrams; Latin runs become lowercase words.
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var cjk: [Character] = [], word = ""
        func flushCJK() {
            if cjk.count == 1 { out.append(String(cjk[0])) }
            else if cjk.count > 1 { for i in 0..<(cjk.count - 1) { out.append(String(cjk[i...i + 1])) } }
            cjk = []
        }
        func flushWord() { if word.count >= 2 { out.append(word) }; word = "" }
        for ch in text.lowercased() {
            let value = ch.unicodeScalars.first!.value
            if (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) { flushWord(); cjk.append(ch) }
            else if ch.isLetter || ch.isNumber { flushCJK(); word.append(ch) }
            else { flushCJK(); flushWord() }
        }
        flushCJK(); flushWord()
        return out
    }

    static func rank(_ query: String, in all: [Passage], limit: Int) -> [Passage] {
        let queryTokens = Set(tokens(query))
        guard !queryTokens.isEmpty, !all.isEmpty else { return [] }
        let docs = all.map { tokens($0.title + "\n" + $0.text) }
        let average = max(1, Double(docs.reduce(0) { $0 + $1.count }) / Double(docs.count))
        var frequency: [String: Int] = [:]
        for doc in docs { for token in Set(doc) where queryTokens.contains(token) { frequency[token, default: 0] += 1 } }
        let n = Double(docs.count)
        var scored: [(Int, Double)] = []
        for (index, doc) in docs.enumerated() {
            var counts: [String: Int] = [:]
            for token in doc where queryTokens.contains(token) { counts[token, default: 0] += 1 }
            var score = 0.0
            for (token, tf) in counts {
                let df = Double(frequency[token] ?? 0)
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                let t = Double(tf)
                score += idf * t * 2.2 / (t + 1.2 * (0.25 + 0.75 * Double(doc.count) / average))
            }
            if score > 0 { scored.append((index, score)) }
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return scored.prefix(limit).enumerated().map { rank, item in
            var passage = all[item.0]; passage.id = "S\(rank + 1)"; return passage
        }
    }
}

public struct ChatAnswer: Sendable, Equatable {
    public let text: String
    public let sources: [Passage]
    public init(text: String, sources: [Passage]) { self.text = text; self.sources = sources }

    /// Rejects answers that cite passages which were never retrieved, so a fabricated citation never reaches the user.
    public static func validated(answer: String, cited: [String], available: [Passage]) throws -> ChatAnswer {
        let known = Set(available.map(\.id))
        let pattern = try NSRegularExpression(pattern: "\\[(S[0-9]+)\\]")
        let whole = NSRange(answer.startIndex..., in: answer)
        let inline = pattern.matches(in: answer, range: whole).compactMap { Range($0.range(at: 1), in: answer).map { String(answer[$0]) } }
        guard Set(cited).isSubset(of: known), Set(inline).isSubset(of: known) else {
            throw ThoughtError.message("回答引用了不存在的來源，已丟棄以避免錯誤資訊。請再問一次。")
        }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ThoughtError.message("LLM 回傳空白回答。") }
        let isInsufficient = trimmed.hasPrefix("知識庫裡沒有足夠資料")
        if isInsufficient {
            guard cited.isEmpty, inline.isEmpty else {
                throw ThoughtError.message("知識庫不足的回答不應引用來源，已丟棄以避免混淆。請再問一次。")
            }
            return ChatAnswer(text: trimmed, sources: [])
        }
        // A non-fallback answer must be grounded in visible citations, not merely a sources field.
        // This catches malformed replies such as "test" before they reach the chat history.
        guard !inline.isEmpty, Set(cited) == Set(inline) else {
            throw ThoughtError.message("模型回覆沒有附上可核對的來源標記，已不採用。請再問一次。")
        }
        let answerWithoutCitations = pattern.stringByReplacingMatches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let cjkCount = answerWithoutCitations.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }.count
        guard cjkCount >= 6 else {
            throw ThoughtError.message("模型回覆內容過短或不完整，已不採用。請再問一次。")
        }
        let used = Set(cited).union(inline)
        return ChatAnswer(text: trimmed, sources: available.filter { used.contains($0.id) })
    }
}
