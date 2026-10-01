import Foundation
import Testing
@testable import ThoughtCore

struct RetrievalTests {
    private func wiki() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ThoughtDrop-wiki-\(UUID())")
        _ = try Archive(root: root)
        let topics = root.appendingPathComponent("wiki/generated/topics")
        try "---\ntitle: \"x\"\n---\n\n# 咖啡店故事\n\n## 2026-10-01\n\n主角是一位收集城市聲音的旅人，想先寫開場。\n\n來源：[[a]]\n".write(to: topics.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "# 論文方向\n\n## 2026-10-02\n\n想比較 Whisper 與 Apple 語音辨識在中英夾雜時的錯誤率。\n".write(to: topics.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try "# 運動\n\n## 2026-10-03\n\n週末想去打羽毛球。\n".write(to: root.appendingPathComponent("wiki/personal/sport.md"), atomically: true, encoding: .utf8)
        try "# 索引\n\n## 主題\n\n咖啡店故事 論文方向 羽毛球\n".write(to: root.appendingPathComponent("wiki/generated/index.md"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func findsRelevantChineseAndMixedPassages() throws {
        let root = try wiki(); defer { try? FileManager.default.removeItem(at: root) }
        let retriever = WikiRetriever(root: root)
        let story = try retriever.search("我之前想寫的那個城市聲音的故事")
        #expect(story.first?.title.contains("咖啡店故事") == true)
        #expect(story.first?.id == "S1")
        let asr = try retriever.search("Whisper 的錯誤率")
        #expect(asr.first?.path.hasSuffix("b.md") == true)
        #expect(try retriever.search("量子計算").isEmpty)
    }

    @Test func skipsIndexPlaceholderFrontmatterAndSymlinks() throws {
        let root = try wiki(); defer { try? FileManager.default.removeItem(at: root) }
        let all = try WikiRetriever(root: root).passages()
        #expect(!all.contains { $0.path.hasSuffix("index.md") || $0.path.hasSuffix("README.md") })
        #expect(!all.contains { $0.text.contains("title:") })
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID()).md")
        try "# 私密\n\n## x\n\n不該被讀到的內容".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("wiki/personal/link.md"), withDestinationURL: outside)
        #expect(!(try WikiRetriever(root: root).passages()).contains { $0.text.contains("不該被讀到") })
    }

    @Test func answerValidationRejectsInventedCitations() throws {
        var a = Passage(path: "wiki/p.md", title: "T", text: "t"); a.id = "S1"
        let ok = try ChatAnswer.validated(answer: "這份筆記確實有寫到相關資訊。[S1]", cited: ["S1"], available: [a])
        #expect(ok.sources == [a])
        #expect(throws: (any Error).self) { try ChatAnswer.validated(answer: "有寫到。[S2]", cited: ["S1"], available: [a]) }
        #expect(throws: (any Error).self) { try ChatAnswer.validated(answer: "有寫到。", cited: ["S9"], available: [a]) }
        #expect(throws: (any Error).self) { try ChatAnswer.validated(answer: "  ", cited: [], available: [a]) }
        #expect(try ChatAnswer.validated(answer: "知識庫裡沒有足夠資料", cited: [], available: [a]).sources.isEmpty)
        #expect(throws: (any Error).self) { try ChatAnswer.validated(answer: "test", cited: ["S1"], available: [a]) }
        #expect(throws: (any Error).self) { try ChatAnswer.validated(answer: "這是一段看似合理但沒有引用的中文回答", cited: ["S1"], available: [a]) }
        #expect(throws: (any Error).self) { try ChatAnswer.validated(answer: "test [S1]", cited: ["S1"], available: [a]) }
    }

    @Test func chatIsSavedOutsideTheWiki() throws {
        let root = try wiki(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Archive(root: root)
        var p = Passage(path: "wiki/personal/sport.md", title: "運動", text: "t"); p.id = "S1"
        let answer = ChatAnswer(text: "你想打羽毛球。[S1]", sources: [p])
        try archive.saveChat(id: "2026-10-01-120000", started: Date(), turns: [("週末想做什麼？", answer, Date())])
        let saved = try String(contentsOf: root.appendingPathComponent("chats/2026-10-01-120000.md"), encoding: .utf8)
        #expect(saved.contains("週末想做什麼？") && saved.contains("../wiki/personal/sport.md"))
        #expect(!(try WikiRetriever(root: root).passages()).contains { $0.text.contains("你想打羽毛球") })
        #expect(throws: (any Error).self) { try archive.saveChat(id: "../evil", started: Date(), turns: []) }
    }
}
