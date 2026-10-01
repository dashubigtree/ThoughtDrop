import Foundation

public enum VaultLocation {
    /// Resolution order: `THOUGHTDROP_VAULT` environment variable, then the first line of
    /// `~/.config/thoughtdrop/vault-path` (works for apps launched from Finder), then `~/Documents/ObsidianVault`.
    public static var defaultVault: URL {
        resolve(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    public static func resolve(environment: [String: String], home: URL) -> URL {
        let configured = environment["THOUGHTDROP_VAULT"]
            ?? (try? String(contentsOf: home.appendingPathComponent(".config/thoughtdrop/vault-path"), encoding: .utf8))
        let path = configured?.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !path.isEmpty else { return home.appendingPathComponent("Documents/ObsidianVault", isDirectory: true) }
        let expanded = path == "~" || path.hasPrefix("~/") ? home.path + path.dropFirst() : path
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    public static var defaultRoot: URL { defaultVault.appendingPathComponent("ThoughtDrop", isDirectory: true) }

    /// Copy once, keep the original, and refuse conflicting destination content.
    public static func prepare(vault: URL, legacy: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: vault.appendingPathComponent(".obsidian").path) else {
            throw ThoughtError.message("找不到 Obsidian vault：\(vault.path)。請確認資料夾存在，或以環境變數 THOUGHTDROP_VAULT、設定檔 ~/.config/thoughtdrop/vault-path 指定 vault 路徑；尚未改用其他儲存位置。")
        }
        let root = vault.appendingPathComponent("ThoughtDrop")
        if fm.fileExists(atPath: root.path), try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw ThoughtError.message("ThoughtDrop 目的地是符號連結，請先確認實際儲存位置。")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent(".legacy-import-complete")
        guard !fm.fileExists(atPath: marker.path) else { return root }
        var copies: [(URL, URL, Bool)] = []
        if fm.fileExists(atPath: legacy.path) {
            let sourceRoot = legacy.resolvingSymlinksInPath()
            guard let items = fm.enumerator(atPath: sourceRoot.path) else {
                throw ThoughtError.message("無法讀取舊資料夾：\(legacy.path)")
            }
            for case let relative as String in items {
                let source = sourceRoot.appendingPathComponent(relative)
                let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw ThoughtError.message("舊資料夾含符號連結，請先確認檔案後再搬移。") }
                let target = root.appendingPathComponent(relative)
                if fm.fileExists(atPath: target.path) {
                    let targetValues = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard targetValues.isSymbolicLink != true,
                          targetValues.isDirectory == values.isDirectory,
                          values.isDirectory == true || fm.contentsEqual(atPath: source.path, andPath: target.path) else {
                        throw ThoughtError.message("新舊位置有不同內容：\(relative)。已保留兩邊原檔，請先處理衝突。")
                    }
                } else { copies.append((source, target, values.isDirectory == true)) }
            }
            for (source, target, isDirectory) in copies {
                if isDirectory { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
                else { try fm.copyItem(at: source, to: target) }
            }
        }
        try "Original retained at: \(legacy.path)\n".write(to: marker, atomically: true, encoding: .utf8)
        return root
    }

    public static func openURL(vault: URL, file: URL) -> URL? {
        guard file.path.hasPrefix(vault.path + "/") else { return nil }
        var url = URLComponents()
        url.scheme = "obsidian"; url.host = "open"
        url.queryItems = [URLQueryItem(name: "vault", value: vault.lastPathComponent),
                         URLQueryItem(name: "file", value: String(file.path.dropFirst(vault.path.count + 1)))]
        return url.url
    }
}
