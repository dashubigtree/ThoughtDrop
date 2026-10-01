import Foundation
import Darwin

public enum LLMProvider: String, CaseIterable, Identifiable, Sendable {
    case codex, claude, openAI
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .codex: return "ChatGPT 訂閱 · Codex CLI"
        case .claude: return "Claude 訂閱 · Claude Code"
        case .openAI: return "OpenAI API · 另外計費"
        }
    }
}

public struct CLITransport: Sendable {
    public let provider: LLMProvider
    public let model: String
    public init(provider: LLMProvider, model: String = "") { self.provider = provider; self.model = model }

    public static func executable(for provider: LLMProvider) -> URL? {
        let name = provider == .codex ? "codex" : "claude"
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":").filter { $0.hasPrefix("/") }
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// No API keys, nested agent state, provider overrides or shell startup scripts are inherited.
    public static func environment(_ source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = source.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SSL_CERT_FILE"].contains($0.key) }
        result["HOME"] = NSHomeDirectory()
        result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return result
    }

    public func request(instructions: String, input: String, schema: [String: Any]) async throws -> Data {
        guard let executable = Self.executable(for: provider) else {
            throw ThoughtError.message("找不到 \(provider == .codex ? "Codex CLI" : "Claude Code")。請先安裝官方命令列工具並登入訂閱帳號。")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ThoughtDrop-LLM-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = try await Self.run(executable: executable, arguments: provider == .codex ? ["login", "status"] : ["auth", "status"], input: "", directory: directory, timeout: 20)
        try Self.validateSubscription(provider: provider, result: auth)
        let schemaURL = directory.appendingPathComponent("schema.json")
        try JSONSerialization.data(withJSONObject: schema).write(to: schemaURL, options: .atomic)
        let result = try await Self.run(executable: executable, arguments: arguments(directory: directory, schema: schema, instructions: instructions),
            input: provider == .codex ? instructions + "\n\n請只處理下列素材，直接回傳符合 schema 的 JSON；不要使用工具或讀取其他檔案。\n\n" + input : input,
            directory: directory, timeout: 240)
        guard result.status == 0 else {
            throw ThoughtError.message("\(provider.title) 未完成（exit \(result.status)）。請檢查網路、訂閱額度或 CLI 登入狀態；不會自動改用付費 API。")
        }
        if provider == .codex {
            let data = try Data(contentsOf: directory.appendingPathComponent("result.json"))
            _ = try JSONSerialization.jsonObject(with: data)
            return data
        }
        return try Self.claudeOutput(result.stdout)
    }

    public func arguments(directory: URL, schema: [String: Any], instructions: String) -> [String] {
        var args: [String]
        if provider == .codex {
            args = ["exec", "--ignore-user-config", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only",
                    "-c", "approval_policy=\"never\"", "-c", "forced_login_method=\"chatgpt\"",
                    "-c", "project_doc_max_bytes=0", "-c", "web_search=\"disabled\"",
                    "--disable", "shell_tool", "--disable", "apps", "--disable", "plugins", "--disable", "multi_agent",
                    "--output-schema", directory.appendingPathComponent("schema.json").path,
                    "--output-last-message", directory.appendingPathComponent("result.json").path, "--color", "never"]
        } else {
            // Schema is app-authored, never transcript text; transcript goes through stdin.
            let schemaText = (try? JSONSerialization.data(withJSONObject: schema)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            args = ["--print", "--safe-mode", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                    "--permission-mode", "dontAsk", "--no-session-persistence", "--output-format", "json",
                    "--json-schema", schemaText, "--system-prompt", instructions]
        }
        if !model.isEmpty { args += ["--model", model] }
        if provider == .codex { args.append("-") }
        return args
    }

    public struct Result: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: Data
        public init(status: Int32, stdout: Data, stderr: Data = Data()) { self.status = status; self.stdout = stdout; self.stderr = stderr }
    }

    public static func validateSubscription(provider: LLMProvider, result: Result) throws {
        let authenticated: Bool
        if provider == .codex {
            let text = String(decoding: result.stdout + result.stderr, as: UTF8.self)
            authenticated = result.status == 0 && text.contains("Logged in using ChatGPT")
        } else {
            let body = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any]
            authenticated = result.status == 0 && body?["loggedIn"] as? Bool == true && body?["authMethod"] as? String == "claude.ai"
        }
        guard authenticated else {
            throw ThoughtError.message(provider == .codex ? "請在 Terminal 執行 codex login，選擇 ChatGPT 帳號登入；此模式不接受 API 金鑰登入。" : "請在 Terminal 執行 claude auth login，以 Claude 訂閱帳號登入；此模式不接受 Console／API 金鑰登入。")
        }
    }

    public static func claudeOutput(_ data: Data) throws -> Data {
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["is_error"] as? Bool == false, body["subtype"] as? String == "success",
              let structured = body["structured_output"] as? [String: Any] else {
            throw ThoughtError.message("Claude Code 未提供完整結構化結果；原始資料已保留。")
        }
        return try JSONSerialization.data(withJSONObject: structured)
    }

    /// Files instead of output pipes prevent a verbose CLI from filling a pipe and deadlocking.
    public static func run(executable: URL, arguments: [String], input: String, directory: URL, timeout: TimeInterval) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let id = UUID().uuidString
                    let inputURL = directory.appendingPathComponent(id + ".stdin")
                    let outputURL = directory.appendingPathComponent(id + ".stdout")
                    let errorURL = directory.appendingPathComponent(id + ".stderr")
                    for url in [inputURL, outputURL, errorURL] {
                        guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                            throw ThoughtError.message("無法建立 CLI 暫存檔。")
                        }
                    }
                    defer { for url in [inputURL, outputURL, errorURL] { try? FileManager.default.removeItem(at: url) } }
                    try Data(input.utf8).write(to: inputURL)
                    let stdin = try FileHandle(forReadingFrom: inputURL)
                    let stdout = try FileHandle(forWritingTo: outputURL)
                    let stderr = try FileHandle(forWritingTo: errorURL)
                    defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
                    let process = Process()
                    process.executableURL = executable; process.arguments = arguments
                    process.currentDirectoryURL = directory; process.environment = environment()
                    process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
                    try process.run()
                    let deadline = Date().addingTimeInterval(timeout)
                    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                    if process.isRunning {
                        process.terminate()
                        let grace = Date().addingTimeInterval(2)
                        while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        process.waitUntilExit()
                        throw ThoughtError.message("CLI 回應逾時，已停止這次工作；原始資料保留，可稍後重試。")
                    }
                    process.waitUntilExit()
                    continuation.resume(returning: Result(status: process.terminationStatus,
                        stdout: try Data(contentsOf: outputURL), stderr: try Data(contentsOf: errorURL)))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
