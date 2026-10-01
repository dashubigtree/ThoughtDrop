import SwiftUI
import ThoughtCore

// Use the property wrapper explicitly: CLT SDKs may omit SwiftUI's newer macro plugin.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct CaptureView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var settings = false
    private let ink = Color(red: 0.18, green: 0.24, blue: 0.23)
    private let green = Color(red: 0.24, green: 0.48, blue: 0.38)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(model.recording ? green : Color.gray.opacity(0.5)).frame(width: 6, height: 6)
                    Text("拾念").font(.system(size: 13, weight: .medium))
                }
                Spacer()
                Button(action: model.showChat) { Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 15)) }
                    .buttonStyle(.plain).help("與知識庫對話").accessibilityLabel("與知識庫對話")
                Menu {
                    Button("與知識庫對話…", action: model.showChat)
                    Button("設定…") { settings = true }
                    Button("開啟儲存資料夾", action: model.openFolder)
                    Button("開啟知識庫", action: model.openWiki)
                    Button("開啟最近回顧", action: model.openReview)
                    Divider()
                    Button("現在整理今天", action: model.summarizeToday)
                        .disabled(model.processing || model.summarizing || model.recording || model.starting)
                    Button("重試未完成筆記（\(model.pendingCount)）", action: model.retryPending).disabled(model.processing)
                    Divider()
                    Button("結束拾念") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 18)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                .accessibilityLabel("更多操作")
            }.padding(.horizontal, 28).padding(.top, 32)

            Spacer().frame(height: 32)
            Text(model.recording ? "讓想法，留下來。" : "一閃而過，也能留下。").font(.system(size: 23, weight: .medium, design: .serif))
            Text(model.recording ? "不用整理，照著你的節奏說。" : "按一下，把腦中的念頭說出來。")
                .font(.system(size: 12)).foregroundStyle(ink.opacity(0.58)).padding(.top, 10)

            ZStack {
                if model.recording {
                    TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { context in
                        let wave = reduceMotion ? 0.5 : (sin(context.date.timeIntervalSinceReferenceDate * .pi / 1.6) + 1) / 2
                        Circle().fill(green.opacity(0.055 + 0.035 * wave)).frame(width: 172 + 16 * wave, height: 172 + 16 * wave)
                        Circle().stroke(green.opacity(0.1 + 0.12 * wave), lineWidth: 1).frame(width: 150 + 20 * wave, height: 150 + 20 * wave)
                    }
                } else {
                    Circle().stroke(ink.opacity(0.065), lineWidth: 1).frame(width: 172, height: 172)
                }
                Button(action: model.toggleRecording) {
                    ZStack {
                        Circle().fill(model.recording ? green : Color(red: 0.67, green: 0.69, blue: 0.67))
                        Image(systemName: model.starting ? "ellipsis" : model.recording ? "stop.fill" : "mic.fill")
                            .font(.system(size: model.recording ? 26 : 32, weight: .medium)).foregroundStyle(.white)
                    }.frame(width: 112, height: 112)
                }
                .buttonStyle(.plain).disabled(model.starting)
                .accessibilityLabel(model.recording ? "停止錄音" : "開始錄音")
                .help("⌘⇧空白鍵：開始／停止錄音")
            }.frame(height: 204).padding(.top, 8)

            Text(model.recording ? String(format: "%02d:%02d", Int(model.seconds) / 60, Int(model.seconds) % 60) : "隨時可以開始")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
            Text(model.recording ? "再按一下停止 · 每段最長 55 秒" : model.shortcutAvailable ? "⌘  ⇧  空白鍵" : "快捷鍵已被佔用，請使用錄音按鈕")
                .font(.system(size: 10)).foregroundStyle(ink.opacity(0.5)).padding(.top, 9)

            Spacer(minLength: 18)
            if let error = model.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(Color(red: 0.62, green: 0.29, blue: 0.2))
                    .lineLimit(3).textSelection(.enabled).padding(.horizontal, 24).help(error)
            } else {
                Text(model.summarizing ? "正在整理回顧與知識庫…" : model.processing ? "正在整理文字，你可以繼續錄音" : model.message)
                    .font(.system(size: 11)).foregroundStyle(ink.opacity(0.62)).lineLimit(2).padding(.horizontal, 24)
            }
            HStack {
                Text("今天已拾起 \(model.todayCount) 個想法")
                Spacer()
                Text("17:00 每日回顧").foregroundStyle(green)
            }.font(.system(size: 10)).padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 22)
        }
        .frame(width: 440, height: 540)
        .foregroundStyle(ink)
        .background(Color(red: 0.97, green: 0.96, blue: 0.93))
        .preferredColorScheme(.light)
        .sheet(isPresented: $settings) { SettingsView(model: model) }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @ViewState private var key = ""
    @ViewState private var modelName = ""
    @ViewState private var local = true
    @ViewState private var login = false
    @ViewState private var error: String?
    @ViewState private var provider: LLMProvider = .codex
    @ViewState private var speech: SpeechSource = .apple
    @ViewState private var geminiKey = ""
    @ViewState private var geminiModel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("替想法找個家").font(.title2.weight(.medium))
            Text("錄音與 Markdown 存在 Obsidian vault。逐字稿會傳送至所選服務，進行校正與每日整理。")
                .font(.callout).foregroundStyle(.secondary)
            Picker("LLM 來源", selection: $provider) {
                ForEach(LLMProvider.allCases) { Text($0.title).tag($0) }
            }
            VStack(alignment: .leading, spacing: 8) {
                if provider == .openAI {
                    Text("OpenAI API 金鑰").font(.caption.weight(.semibold))
                    SecureField("留白保留鑰匙圈原有金鑰", text: $key)
                    TextField("模型名稱", text: $modelName)
                    Text("API 另外計費，不使用 ChatGPT 訂閱額度。").font(.caption2).foregroundStyle(.secondary)
                } else {
                    TextField("模型（留白使用 CLI 預設）", text: $modelName)
                    Text(provider == .codex ? "首次請在 Terminal 執行 codex login，以 ChatGPT 帳號登入。" : "首次請在 Terminal 執行 claude auth login，以 Claude 訂閱帳號登入。")
                        .font(.caption).textSelection(.enabled)
                    Text("使用官方 CLI 的既有登入與訂閱額度；不需常開 Terminal。額度不足時保留資料，不會自動改用 API。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.textFieldStyle(.roundedBorder)
            HStack {
                Button(model.checkingConnection ? "測試中…" : "測試已儲存的連線", action: model.checkConnection)
                    .disabled(model.checkingConnection || model.processing || model.summarizing)
                if let message = model.connectionMessage { Text(message).font(.caption).lineLimit(3).help(message) }
            }
            Picker("語音辨識來源", selection: $speech) {
                ForEach(SpeechSource.allCases) { Text($0.title).tag($0) }
            }
            if speech == .gemini {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField(model.hasGeminiKey ? "留白保留鑰匙圈原有金鑰" : "Google AI Studio 金鑰", text: $geminiKey)
                    TextField("Gemini 模型名稱", text: $geminiModel)
                    Text("錄音檔會上傳至 Google 辨識，不再只在本機處理。免費層的資料可能被 Google 用於改善產品，請自行確認條款；用量依你的 AI Studio 方案計算，不使用 ChatGPT／Claude 訂閱額度。")
                        .font(.caption2).foregroundStyle(.secondary)
                    if model.hasGeminiKey {
                        Button("移除 Gemini 金鑰", role: .destructive) {
                            do { try model.removeGeminiKey(); speech = .apple } catch { self.error = error.localizedDescription }
                        }
                    }
                }.textFieldStyle(.roundedBorder)
            }
            Toggle("Apple 辨識只使用本機", isOn: $local)
            Text("關閉後允許 Apple 線上語音辨識，音訊可能傳送至 Apple。本機辨識可用性依裝置與語言而異。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("登入 Mac 時啟動", isOn: $login)
            Text("每日 17:00 按 Mac 時區整理。請讓 App 在選單列運作；睡眠或退出期間的工作會於喚醒或下次啟動補做。")
                .font(.caption).foregroundStyle(.secondary)
            Text("儲存位置：\(model.root.path)").font(.caption2).textSelection(.enabled)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if provider == .openAI {
                    Button("移除金鑰", role: .destructive) {
                        do { try model.removeKey() } catch { self.error = error.localizedDescription }
                    }
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("儲存") {
                    do {
                        try model.saveSettings(provider: provider, key: key, model: modelName, local: local, login: login,
                                               speech: speech, geminiKey: geminiKey, geminiModel: geminiModel)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 470)
            .onAppear { provider = model.provider; modelName = model.provider == .openAI ? model.modelName : model.cliModel; local = model.localOnly; login = model.launchAtLogin
                speech = model.speechSource; geminiModel = model.geminiModel }
            .onChange(of: provider) { _, value in
                modelName = value == .openAI ? model.modelName : UserDefaults.standard.string(forKey: value.rawValue + "Model") ?? ""
            }
    }
}
