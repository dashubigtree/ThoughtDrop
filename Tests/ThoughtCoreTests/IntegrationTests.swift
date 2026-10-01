import Foundation
import Testing
@testable import ThoughtCore

struct IntegrationTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ThoughtDrop-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func subscriptionOnlyAuth() throws {
        try CLITransport.validateSubscription(provider: .codex, result: .init(status: 0, stdout: Data(), stderr: Data("Logged in using ChatGPT".utf8)))
        #expect(throws: (any Error).self) {
            try CLITransport.validateSubscription(provider: .codex, result: .init(status: 0, stdout: Data("Logged in using an API key".utf8)))
        }
        try CLITransport.validateSubscription(provider: .claude, result: .init(status: 0, stdout: Data(#"{"loggedIn":true,"authMethod":"claude.ai"}"#.utf8)))
        #expect(throws: (any Error).self) {
            try CLITransport.validateSubscription(provider: .claude, result: .init(status: 0, stdout: Data(#"{"loggedIn":true,"authMethod":"api_key"}"#.utf8)))
        }
    }
    @Test func environmentDoesNotLeakAPIKeysOrNestedAgentState() {
        let environment = CLITransport.environment(["OPENAI_API_KEY": "test", "ANTHROPIC_API_KEY": "test", "CODEX_API_KEY": "test", "CLAUDECODE": "1", "CODEX_THREAD_ID": "test", "HOME": "/other", "PATH": "/untrusted"])
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["CODEX_API_KEY"] == nil)
        #expect(environment["CLAUDECODE"] == nil)
        #expect(environment["CODEX_THREAD_ID"] == nil)
        #expect(environment["HOME"] == NSHomeDirectory())
        #expect(environment["PATH"]?.contains("/untrusted") == false)
    }
    @Test func cliIsIsolatedAndDoesNotUseShellArgumentsForTranscript() {
        let directory = URL(fileURLWithPath: "/tmp/example")
        let codex = CLITransport(provider: .codex).arguments(directory: directory, schema: [:], instructions: "instruction")
        #expect(codex.contains("read-only")); #expect(codex.contains("--ignore-user-config"))
        #expect(codex.contains("forced_login_method=\"chatgpt\""))
        #expect(codex.last == "-")
        let claude = CLITransport(provider: .claude).arguments(directory: directory, schema: [:], instructions: "instruction")
        #expect(claude.contains("--safe-mode")); #expect(claude.contains("--strict-mcp-config"))
        #expect(claude.contains("--no-session-persistence")); #expect(claude.contains("dontAsk"))
    }
    @Test func claudeStructuredOutputAndErrors() throws {
        let result = try CLITransport.claudeOutput(Data(#"{"is_error":false,"subtype":"success","structured_output":{"corrected":"測試"}}"#.utf8))
        let decoded = try JSONSerialization.jsonObject(with: result) as? [String: String]
        #expect(decoded?["corrected"] == "測試")
        #expect(throws: (any Error).self) { try CLITransport.claudeOutput(Data(#"{"is_error":true,"subtype":"success","structured_output":{}}"#.utf8)) }
        #expect(throws: (any Error).self) { try CLITransport.claudeOutput(Data(#"{"is_error":false,"subtype":"error_max_turns","structured_output":{}}"#.utf8)) }
    }
    @Test func processStdinIsLiteralAndLargeOutputDoesNotDeadlock() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = "$(touch /tmp/should-never-execute) `echo test`\n" + String(repeating: "測試", count: 60_000)
        let result = try await CLITransport.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: input, directory: directory, timeout: 5)
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == input)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
    @Test func processTimesOut() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: (any Error).self) {
            try await CLITransport.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], input: "", directory: directory, timeout: 0.1)
        }
    }
    @Test func migrationCopiesOnceAndNeverDeletesOriginal() throws {
        let base = try temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = base.appendingPathComponent("vault")
        let legacy = base.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "original".write(to: legacy.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        let root = try VaultLocation.prepare(vault: vault, legacy: legacy)
        #expect(try String(contentsOf: root.appendingPathComponent("note.md")) == "original")
        #expect(try String(contentsOf: legacy.appendingPathComponent("note.md")) == "original")
        try "newer".write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        _ = try VaultLocation.prepare(vault: vault, legacy: legacy)
        #expect(try String(contentsOf: root.appendingPathComponent("note.md")) == "newer")
    }
    @Test func migrationRefusesConflictsAndMissingVault() throws {
        let base = try temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent("old")
        let vault = base.appendingPathComponent("vault")
        #expect(throws: (any Error).self) { try VaultLocation.prepare(vault: vault, legacy: legacy) }
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("ThoughtDrop"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "source".write(to: legacy.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        let destination = vault.appendingPathComponent("ThoughtDrop/note.md")
        try "destination".write(to: destination, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try VaultLocation.prepare(vault: vault, legacy: legacy) }
        #expect(try String(contentsOf: destination) == "destination")
    }
    @Test func obsidianFrontmatterLinksAndOpenURL() throws {
        let base = try temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("ThoughtDrop")
        let archive = try Archive(root: root, vault: base)
        var clip = Clip(); clip.raw = "測試"; clip.status = .transcribed
        try archive.save(clip)
        try archive.persistReport(.init(review: "回顧", tomorrow: "代辦", notes: [.init(title: "測試主題", kind: "knowledge", content: "測試", sources: [clip.id])]), day: clip.day, clips: [clip])
        let review = root.appendingPathComponent("days/\(clip.day)/一日回顧.md")
        let content = try String(contentsOf: review)
        #expect(content.hasPrefix("---\ntitle:"))
        #expect(content.contains("[[ThoughtDrop/days/\(clip.day)/transcripts/\(clip.id)|"))
        let url = try #require(VaultLocation.openURL(vault: base, file: review))
        #expect(url.scheme == "obsidian")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "file" })?.value == "ThoughtDrop/days/\(clip.day)/一日回顧.md")
    }
}

struct VaultResolveTests {
    @Test func environmentThenConfigFileThenDefault() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ThoughtDrop-home-\(UUID())")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/thoughtdrop"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(VaultLocation.resolve(environment: [:], home: home).path == home.path + "/Documents/ObsidianVault")
        try "~/Notes\n".write(to: home.appendingPathComponent(".config/thoughtdrop/vault-path"), atomically: true, encoding: .utf8)
        #expect(VaultLocation.resolve(environment: [:], home: home).path == home.path + "/Notes")
        #expect(VaultLocation.resolve(environment: ["THOUGHTDROP_VAULT": "/tmp/vault"], home: home).path == "/tmp/vault")
    }
}
