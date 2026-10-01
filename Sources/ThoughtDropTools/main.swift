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
        default:
            print("用法：ThoughtDropTools prepare-vault | check-codex | check-claude")
        }
    }
}
