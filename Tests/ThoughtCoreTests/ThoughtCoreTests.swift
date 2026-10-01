import Foundation
import Testing
@testable import ThoughtCore

final class ThoughtCoreTests {
    private var tempRoots: [URL] = []
    deinit { for root in tempRoots { try? FileManager.default.removeItem(at: root) } }
    private func calendar(_ zone: String = "Asia/Taipei") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func store() throws -> Archive {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ThoughtDrop-test-\(UUID())")
        tempRoots.append(root)
        return try Archive(root: root)
    }
    private func clip(_ text: String = "明天寫下三個故事開頭") -> Clip {
        var clip = Clip(date: date("2026-10-01T08:00:00Z"), calendar: calendar())
        clip.raw = text; clip.status = .transcribed
        return clip
    }
    private func report(_ clip: Clip, title: String = "創作") -> DailyReport {
        DailyReport(review: "今天想寫故事。", tomorrow: "- [ ] 建議：先寫一個開頭。", notes: [
            WikiNote(title: title, kind: "memory", content: "想試著寫故事。", sources: [clip.id])
        ])
    }

    @Test func testScheduleAtFiveAndCatchUp() {
        let cal = calendar()
        #expect(!(Day.isDue("2026-10-01", now: date("2026-10-01T08:59:59Z"), calendar: cal)))
        #expect(Day.isDue("2026-10-01", now: date("2026-10-01T09:00:00Z"), calendar: cal))
        #expect(Day.isDue("2026-09-30", now: date("2026-10-01T00:00:00Z"), calendar: cal))
        #expect(!(Day.isDue("2026-10-02", now: date("2026-10-01T12:00:00Z"), calendar: cal)))
    }

    @Test func testDateFollowsLocalMidnightAndDST() {
        #expect(Day.key(date("2026-10-01T16:01:00Z"), calendar: calendar()) == "2026-10-02")
        let cal = calendar("America/New_York")
        #expect(!(Day.isDue("2026-11-01", now: date("2026-11-01T21:59:00Z"), calendar: cal)))
        #expect(Day.isDue("2026-11-01", now: date("2026-11-01T22:00:00Z"), calendar: cal))
    }

    @Test func testRevisionIncludesNewClipsCorrectionsAndFailures() {
        let original = clip()
        var changed = original
        changed.corrected = "明天寫三個故事開頭。"
        #expect(Day.fingerprint([original]) != Day.fingerprint([changed]))
        changed = original; changed.status = .failed
        #expect(Day.fingerprint([original]) != Day.fingerprint([changed]))
        let another = clip("看一場電影")
        #expect(Day.fingerprint([original, another]) == Day.fingerprint([another, original]))
        #expect(Day.fingerprint([original]) != Day.fingerprint([original, another]))
    }

    @Test func testTranscriptRoundTripPreservesOriginal() throws {
        let archive = try store()
        var clip = clip()
        clip.corrected = "明天寫下三個故事開頭。"; clip.status = .complete
        try archive.save(clip)
        let restored = try #require(archive.loadClips().first)
        #expect(restored.raw == clip.raw)
        #expect(restored.corrected == clip.corrected)
        let markdown = try String(contentsOf: archive.folder(clip.day).appendingPathComponent("transcripts/\(clip.id).md"))
        #expect(markdown.contains("## 辨識原文"))
        #expect(markdown.contains("## 校正逐字稿"))
        #expect(archive.audio(clip).pathExtension == "m4a")
    }

    @Test func testReportRetryIsIdempotentAndProtectsPersonalNotes() throws {
        let archive = try store()
        let clip = clip()
        try archive.save(clip)
        let personal = archive.root.appendingPathComponent("wiki/personal/important.md")
        try "不要覆寫我的筆記".write(to: personal, atomically: true, encoding: .utf8)
        for _ in 0..<2 { try archive.persistReport(report(clip), day: clip.day, clips: [clip]) }
        let topics = try FileManager.default.contentsOfDirectory(at: archive.root.appendingPathComponent("wiki/generated/topics"), includingPropertiesForKeys: nil)
        #expect(topics.count == 1)
        let page = try String(contentsOf: #require(topics.first))
        #expect(page.components(separatedBy: "## 2026-10-01").count - 1 == 1)
        #expect(page.contains("../../../days/2026-10-01/transcripts/\(clip.id).md"))
        #expect(try String(contentsOf: personal) == "不要覆寫我的筆記")
        #expect(try archive.reports().count == 1)
    }

    @Test func testInvalidSourcesNeverCommit() throws {
        let archive = try store()
        let clip = clip()
        let invalid = DailyReport(review: "回顧", tomorrow: "代辦", notes: [WikiNote(title: "主題", kind: "memory", content: "內容", sources: ["invented-id"])])
        #expect(throws: (any Error).self) { try archive.persistReport(invalid, day: clip.day, clips: [clip]) }
        #expect(try archive.reports().isEmpty)
    }

    @Test func testTopicTitlesCannotEscapeGeneratedDirectory() throws {
        let archive = try store()
        let clip = clip()
        try archive.persistReport(report(clip, title: "../../escape"), day: clip.day, clips: [clip])
        let topics = try FileManager.default.contentsOfDirectory(atPath: archive.root.appendingPathComponent("wiki/generated/topics").path)
        #expect(topics.count == 1)
        #expect(topics[0].count == 27)
        #expect(!(FileManager.default.fileExists(atPath: archive.root.appendingPathComponent("escape.md").path)))
    }

    @Test func testTopicAccumulatesAcrossDaysAndObsoleteEntriesAreRemoved() throws {
        let archive = try store()
        let first = clip()
        var second = clip("今天寫好了開頭")
        second.day = "2026-10-02"
        try archive.persistReport(report(first), day: first.day, clips: [first])
        try archive.persistReport(report(second), day: second.day, clips: [second])
        let topicFolder = archive.root.appendingPathComponent("wiki/generated/topics")
        let url = try #require(FileManager.default.contentsOfDirectory(at: topicFolder, includingPropertiesForKeys: nil).first)
        let page = try String(contentsOf: url)
        #expect(page.contains("## 2026-10-01")); #expect(page.contains("## 2026-10-02"))
        let empty = DailyReport(review: "回顧", tomorrow: "尚無明確代辦", notes: [])
        try archive.persistReport(empty, day: first.day, clips: [first])
        #expect(FileManager.default.fileExists(atPath: url.path))
        try archive.persistReport(empty, day: second.day, clips: [second])
        #expect(!(FileManager.default.fileExists(atPath: url.path)))
    }

    @Test func testIncompleteRecognitionIsDisclosed() throws {
        let archive = try store()
        let good = clip()
        var failed = clip(""); failed.status = .failed
        try archive.persistReport(report(good), day: good.day, clips: [good, failed])
        let text = try String(contentsOf: archive.folder(good.day).appendingPathComponent("一日回顧.md"))
        #expect(text.contains("未取得逐字稿：1 筆"))
        #expect(text.contains("（未校正）"))
    }

    @Test func testResponseParserHandlesReasoningRefusalAndIncomplete() throws {
        let valid = Data(#"{"status":"completed","output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"{\"corrected\":\"測試\"}"}]}]}"#.utf8)
        #expect(String(decoding: try LLMClient.outputJSON(valid), as: UTF8.self) == #"{"corrected":"測試"}"#)
        #expect(throws: (any Error).self) { try LLMClient.outputJSON(Data(#"{"status":"incomplete","output":[]}"#.utf8)) }
        #expect(throws: (any Error).self) { try LLMClient.outputJSON(Data(#"{"status":"completed","output":[{"content":[{"type":"refusal","refusal":"no"}]}]}"#.utf8)) }
    }
}
