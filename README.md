# 拾念 ThoughtDrop

> 在 Mac 上接住一閃即逝的想法：按一下錄音，語音自動變成校正過的逐字稿，每天傍晚整理成回顧、明日待辦與可累積的 Obsidian 知識庫。

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey) ![swift](https://img.shields.io/badge/Swift-5.9-orange) ![license](https://img.shields.io/badge/license-MIT-blue)

原生 SwiftUI 選單列 App，沒有第三方套件，也不需要完整 Xcode。主畫面只有一顆錄音鈕：錄音時綠色呼吸燈，待機時灰色靜止。

## 為什麼做這個

想法常在走路、洗澡、發呆時出現，打開筆記軟體的瞬間就忘了。我想要的是「零摩擦的捕捉」加上「自動整理」：錄下來就好，之後由 LLM 校正錯字、歸納成每日回顧，並把想法依主題累積進自己的 Obsidian vault，而不是散落在一堆語音備忘錄裡。

## 功能

- **快速錄音**：全域快捷鍵 ⌘⇧空白鍵或選單列按鈕，每段最多 55 秒，適合短想法。
- **可切換的語音辨識**：預設 Apple 語音辨識（zh-TW，可純本機）；也可改用 Google Gemini（AI Studio 金鑰）。
- **LLM 校正與整理**：用既有的 **ChatGPT 訂閱（Codex CLI）** 或 **Claude 訂閱（Claude Code）**，也保留 OpenAI API 模式。
- **每日 17:00 整理**：自動產生「一日回顧」「明日代辦」，並維護跨日累積的主題 Wiki；睡眠或退出後，喚醒時自動補做。
- **Obsidian 原生**：輸出帶 YAML 屬性與 `[[wikilink]]` 的 Markdown，每則 Wiki 條目都附逐字稿來源。
- **失敗不丟資料**：先存音檔，再辨識、再校正；任何一步失敗都保留原始資料，可從選單重試。

## 設計重點

| 取捨 | 做法 | 原因 |
| --- | --- | --- |
| 原生 App 而非網頁／Electron | SwiftUI + AVFoundation + Speech | 選單列常駐、全域快捷鍵、本機檔案與登入啟動最直接；不錄音時不開麥克風，也不跑動畫 |
| 用訂閱額度而非 API | 背景呼叫官方 CLI（`codex exec`、`claude --print`） | 個人自用可沿用既有訂閱；App 不讀取、複製任何 OAuth token 或 cookie，登入由官方 CLI 處理 |
| 不信任模型輸出 | 結構化輸出 + 來源 id 驗證 | 每則 Wiki 條目必須引用真實存在的逐字稿，不通過就不寫入 |
| 隔離 CLI 子程序 | 唯讀 sandbox、停用工具與 MCP、獨立暫存目錄、內容走標準輸入 | 避免逐字稿內容被當成指令，也避免 shell 字串插值 |
| 機器檔與個人檔分離 | `wiki/generated` 會被覆寫、`wiki/personal` 永不覆寫 | 自己的筆記不會被重新整理蓋掉 |
| 辨識原文與校正版並存 | 兩份都存在逐字稿檔 | 可回頭檢查 LLM 有沒有改錯 |

詳細資料結構、排程規則與隱私說明見 [docs/DETAILS.md](docs/DETAILS.md)。

## 架構

```text
Sources/
├── ThoughtCore/        # 與 UI 無關的核心邏輯（可單元測試）
│   ├── Archive         # 檔案儲存、Markdown 產生、Wiki 累積
│   ├── LLMClient       # 校正與每日整理（API 模式）
│   ├── CLITransport    # 官方 CLI 的隔離呼叫與訂閱登入驗證
│   ├── GeminiTranscriber  # Gemini 語音辨識
│   └── VaultLocation   # Obsidian vault 解析與舊資料搬移
├── ThoughtDrop/        # SwiftUI 選單列 App、錄音、設定
└── ThoughtDropTools/   # 維護指令（prepare-vault、check-codex、check-claude）
Tests/                  # 22 項測試
```

## 快速開始

需求：macOS 14 以上、Apple Command Line Tools（`xcode-select --install`）。

```sh
bash scripts/build-app.sh
open dist/ThoughtDrop.app
```

1. 指定你的 Obsidian vault（資料夾需含 `.obsidian`），二擇一：

   ```sh
   mkdir -p ~/.config/thoughtdrop
   echo "/path/to/your/vault" > ~/.config/thoughtdrop/vault-path
   ```

   或設定環境變數 `THOUGHTDROP_VAULT`。都沒設定時預設 `~/Documents/ObsidianVault`。
2. 在 Terminal 登入其中一個 LLM 來源：`codex login` 或 `claude auth login`。
3. 按 ⌘⇧空白鍵開始錄音，再按一次停止；首次會詢問麥克風與語音辨識權限。

所有 App 檔案只會寫在 vault 的 `ThoughtDrop/` 子資料夾，不修改 vault 的其他內容。

## 測試

```sh
bash scripts/test.sh
```

涵蓋 17:00／跨日／夏令時間補做、版本指紋、原文保留、重試不重複寫入、個人筆記保護、來源引用驗證、檔名隔離、vault 路徑解析、CLI 隔離與逾時，以及不完整或被拒絕的 API 回應。

## 目前限制與後續

- 麥克風權限、真實語音品質與各 LLM 來源的實際額度行為，需在使用者的機器上互動驗收，自動化測試未涵蓋。
- 本機開發用 ad-hoc 簽章，尚未 Developer ID 簽署或公證。
- 「隨時喚醒」目前是快捷鍵與選單列，不含語音喚醒詞。
- 尚未實作：iPhone／Apple Watch 入口、跨裝置同步、知識庫問答與語意搜尋、語意相近主題自動去重。
- 訂閱額度僅供個人自用；若要提供給他人，應改用官方 API 計費。

## 隱私

- 預設 Apple 本機辨識，音訊不離開 Mac。改用 Gemini 辨識時，錄音會上傳到 Google。
- 逐字稿與既有主題名稱會送至所選的 LLM 服務；不上傳整個 vault，也不讓 CLI 直接寫筆記。
- API 金鑰只存 macOS 鑰匙圈，不寫入檔案；repo 內沒有任何金鑰或個人資料。

## 開發說明

構想、需求與設計取捨由作者提出，並與 AI 程式助理（Codex、Claude Code）協作實作。

## 授權

[MIT](LICENSE)
