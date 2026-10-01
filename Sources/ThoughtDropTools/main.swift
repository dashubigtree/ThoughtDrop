import Foundation
import ThoughtCore

@main
struct Maintenance {
    static func main() async throws {
        switch CommandLine.arguments.dropFirst().first {
        case "prepare-vault":
            let legacy = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ThoughtDrop")
            let root = try VaultLocation.prepare(vault: VaultLocation.defaultVault, legacy: legacy)
            let archive = try Archive(root: root, vault: VaultLocation.defaultVault)
            let clips = try archive.loadClips()
            for clip in clips { try archive.save(clip) }
            try archive.regenerateDocuments()
            print("知識庫已準備：\(root.path)；保留 \(clips.count) 筆錄音索引，舊資料未刪除。")
        case "check-codex", "check-claude":
            let provider: LLMProvider = CommandLine.arguments[1] == "check-codex" ? .codex : .claude
            let client = LLMClient(provider: provider)
            var clip = Clip()
            clip.raw = "今天想到一個故事，主角是一位收集城市聲音的旅人。明天我想先寫一段開場。"
            clip.corrected = try await client.correct(clip.raw)
            clip.status = .complete
            let report = try await client.summarize(day: clip.day, clips: [clip], existingTitles: [])
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ThoughtDrop-check-\(UUID())")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let archive = try Archive(root: temporary)
            try archive.persistReport(report, day: clip.day, clips: [clip])
            print("\(provider.title)：人工測試文字的校正、每日整理與來源驗證皆成功。未讀取 vault 私人筆記。")
        case "check-chat":
            let provider: LLMProvider = CommandLine.arguments.dropFirst(2).first == "claude" ? .claude : .codex
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ThoughtDrop-chat-check-\(UUID())")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let archive = try Archive(root: temporary)
            try "# 城市聲音故事\n\n## 2026-10-01\n\n想法：主角是一位收集城市聲音的旅人。暫定決定：明天先寫一段開場。\n".write(
                to: temporary.appendingPathComponent("wiki/personal/story.md"), atomically: true, encoding: .utf8)
            _ = archive
            let retriever = WikiRetriever(root: temporary)
            let client = LLMClient(provider: provider)
            let known = try retriever.search("我的故事主角是誰？明天打算做什麼？")
            let answered = try await client.answer(question: "我的故事主角是誰？明天打算做什麼？", history: [], passages: known)
            print("可答問題 →", answered.text, "| 來源：", answered.sources.map(\.id))
            let unknown = try retriever.search("故事主角的血型是什麼？")
            let refused = unknown.isEmpty ? ChatAnswer(text: "（無檢索結果，未呼叫 LLM）", sources: [])
                : try await client.answer(question: "故事主角的血型是什麼？", history: [], passages: unknown)
            print("不可答問題 →", refused.text, "| 來源：", refused.sources.map(\.id))
        default:
            print("用法：ThoughtDropTools prepare-vault | check-codex | check-claude | check-chat [codex|claude]")
        }
    }
}
