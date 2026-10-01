# 拾念 ThoughtDrop：使用與技術細節

> 作品集首頁請見 [README](../README.md)。以下為完整的使用方式、資料結構與設計取捨。

在 Mac 上接住一閃即逝的想法。原生 SwiftUI 選單列 App，主畫面只有一顆錄音按鈕；按一下開始，再按一下停止。錄音時綠色呼吸燈，待機時灰色靜止。

## 執行

需求：macOS 14 以上、Apple Command Line Tools（`xcode-select --install`），不需要完整 Xcode 或第三方套件。

```sh
bash scripts/build-app.sh
open dist/ThoughtDrop.app
```

可把 `dist/ThoughtDrop.app` 複製到「應用程式」後開啟。這是本機開發用 ad-hoc 簽章，尚未做 Developer ID 簽署、公證或 App Store 發布。更新簽章後 macOS 可能重新詢問權限。

1. 按錄音鈕或 **⌘⇧空白鍵**，首次會詢問麥克風權限。
2. 再按一下停止；每段最多 **55 秒**，到時自動保存，適合短想法。語音辨識會另外詢問權限。
3. 預設使用 Apple 繁體中文本機辨識。若裝置不支援，可在右上角 `… → 設定` 關閉「只使用本機語音辨識」，允許 Apple 線上辨識，再選「重試未完成筆記」。
4. LLM 預設為 **ChatGPT 訂閱 · Codex CLI**，以 `codex login` 的既有 ChatGPT 登入執行。CLI 模型欄留白使用官方 CLI 預設模型。
5. 可在設定切換 **Claude 訂閱 · Claude Code**，先在 Terminal 執行 `claude auth login`，以自己的 Claude 訂閱帳號登入。也保留 **OpenAI API** 模式，該模式另外計費，金鑰放在鑰匙圈。
6. 初次登入後不需要常開 Terminal，App 會在背景啟動 CLI；設定中的「測試已儲存的連線」僅傳送人工測試文字。修改來源後先儲存，再重新開啟設定測試。
7. 未連線時仍可錄音和辨識，從選單重試未完成筆記。逐字稿與既有主題名稱會送至所選服務；不把整個 vault 上傳，也不讓 CLI 直接寫筆記。
8. 關閉視窗會繼續在選單列運作。可從設定啟用登入啟動；移至「應用程式」後再啟用較方便管理。

## 語音辨識來源

預設 **Apple 語音辨識**（zh-TW，可只在本機）。在設定的「語音辨識來源」可改選 **Google Gemini**：貼上 Google AI Studio 金鑰（存鑰匙圈，不寫入檔案），模型名稱可自行更換，預設 `gemini-2.5-flash`。

- Gemini 模式會把錄音檔上傳到 Google；免費層資料使用條款請自行確認。用量走 AI Studio 方案，與 ChatGPT／Claude 訂閱無關。
- 失敗（金鑰、額度、模型名稱）時音檔與狀態保留，可從選單重試；不會自動退回 Apple 辨識。
- Gemini 是以 LLM 轉寫，可能偶爾改寫或漏字；原文與校正版仍並存保留。

## 每天下午五點

- 依 **Mac 系統時區**，每天 17:00 後檢查並生成「一日回顧」「明日代辦」與 Wiki。檢查週期約 30 秒，實際完成時間取決於辨識與 API。
- 17:00 後的新筆記會觸發當日文件更新，並非把傍晚想法算成隔天。
- 電腦睡眠、關機、App 退出時不執行。喚醒或下次啟動後會從較早日期補做，無法保證睡眠時準時產出。
- 網路／API 失敗保留資料，每個日期至少相隔 15 分鐘自動重試；選單「現在整理今天」可手動重試。
- 正在錄音或逐字稿處理時會暫緩每日整理。沒有任何可用逐字稿的日期不會憑空生成回顧；部分辨識失敗會在回顧註明缺少幾筆。
- 每日原始錄音按開始錄音的日期歸檔，跨午夜亦同。校正後文字變更或新增錄音都會更新版本指紋。

## 儲存位置

```text
<你的 Obsidian vault>/ThoughtDrop/
├── days/
│   └── 2026-10-01/
│       ├── audio/<UUID>.m4a
│       ├── transcripts/<UUID>.md   # 辨識原文 + 校正版 + 音檔連結
│       ├── metadata/<UUID>.json    # 處理狀態與復原索引
│       ├── 一日回顧.md
│       ├── 明日代辦.md
│       └── report.json            # 可重建文件的整理結果
└── wiki/
    ├── generated/
    │   ├── index.md
    │   ├── memory.md
    │   └── topics/<主題雜湊>.md
    └── personal/                  # 自己編輯的筆記，不會被程式覆寫
```

Wiki 以主題累積跨日內容，每個條目保留日期與逐字稿引用。知識與個人記憶分開標記；模型被要求區分想法、疑問與事實。主題名稱會提供給下次整理以協助沿用，第一版尚不保證語意相近主題自動去重。

`generated`、逐字稿與每日回顧是機器生成檔，重新整理會覆寫。自己的補充請放 `wiki/personal`。備份時應包含整個 ThoughtDrop 資料夾。若此 vault 另有 Obsidian Sync、iCloud 或其他同步機制，會依該機制同步。音檔目前也放在 vault 的每日資料夾。

## 為什麼選原生 App

第一版採 **macOS 原生 App**。SwiftUI、AVFoundation、Speech、ServiceManagement 都是系統框架，不需 Electron、瀏覽器常駐服務或常駐本機 LLM；不錄音時不開麥克風，UI 不播放動畫，只用低頻排程檢查。實際記憶體、電量與辨識品質仍需在目標 Mac 實測。

| 選項 | 此產品的取捨 |
| --- | --- |
| macOS 原生 App（採用） | 選單列、全域快捷鍵、本機音檔與登入啟動較直接；適合隨手捕捉 |
| 網頁 / PWA | 容易跨平台，但生命週期受瀏覽器影響，頁面關閉後無法依賴前端準時整理；適合作為未來回顧介面 |
| iPhone App（下一階段） | 沿用 Swift 資料模型，加入隨手錄音入口；需設計同步與衝突處理 |
| Apple Watch（後續） | 適合極短錄音入口；先同步到手機或 Mac，再完成整理，避免把完整 LLM 工作放在手錶 |

「隨時喚醒」目前指快捷鍵／選單列，不包含語音喚醒詞。語音喚醒需另行設計持續聆聽、耗電與權限流程。iPhone、Watch、跨裝置同步、知識庫問答與語意搜尋尚未實作。

## 驗證

```sh
bash scripts/test.sh
```

測試覆蓋 17:00／跨日／DST 補做、版本指紋、原文保留、報告重試不重複、跨日主題、個人筆記保護、引用驗證、檔名隔離，以及不完整／拒絕的 API 回應。麥克風權限、真實聲音、Apple 辨識品質、API 帳號與登入啟動仍需互動驗收。

## 官方參考

- [Apple：從音訊檔案辨識語音](https://developer.apple.com/documentation/speech/sfspeechurlrecognitionrequest)
- [Apple：登入服務註冊](https://developer.apple.com/documentation/servicemanagement/smappservice/register())
- [OpenAI：Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs)

API 模式使用 `store: false`；CLI 模式使用臨時會話與短期暫存檔。這不等於供應商完全不保留資料，仍以帳號適用的政策為準。


## 訂閱與 Terminal 的取捨

個人自用、希望使用既有訂閱額度時，背景呼叫官方 CLI 適合這個 App：`codex exec` 或 `claude --print`。這不是把 ChatGPT／Claude 網頁訂閱轉成 API，也不會讀取、複製、匯出 OAuth token 或瀏覽器 cookie。登入由官方 CLI 自己處理。

- ChatGPT 來源使用 Codex 的訂閱額度；Claude 來源使用 Claude Code 與 Claude 共用的額度。額度、可用模型、帳號／工作區政策仍會限制使用；不要視為無限量或保證零額外費用（供應商帳號若另行啟用加購用量，仍依其設定）。
- CLI 每次啟動比直接 API 請求更重、延遲更長，也較依賴 CLI 版本、登入期限與用量限制。正式對外發布、多使用者服務或要求穩定延遲時，應改用官方 API。
- App 僅接受 CLI 的訂閱登入狀態，清除子程序繼承的 API key 環境變數；不自動切換來源或啟用付費 API。
- Codex 以唯讀 sandbox 執行，忽略使用者專案設定、關閉 shell、插件、Apps、網頁搜尋與多代理工具；Claude 使用 safe mode、停用工具與 MCP。兩者都在獨立暫存目錄工作，內容經標準輸入傳入，沒有 shell 字串插值。
- CLI 每次請求最多等待 240 秒；結束後清除 App 的暫存輸入／輸出。額度或連線失敗仍保留原始音檔和逐字稿。
- Claude 訂閱適用於本人使用未修改的官方 Claude Code。若把產品提供給其他人，應使用官方支援的 API 計費，不收集或代理他們的 Claude 訂閱憑證。

官方說明：[Codex 非互動執行](https://developers.openai.com/codex/noninteractive)、[Codex 登入](https://developers.openai.com/codex/auth)、[Claude Code 程式化執行](https://code.claude.com/docs/en/headless)、[Claude 訂閱登入與限制](https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-or-max-plan)、[Claude 憑證使用說明](https://code.claude.com/docs/en/legal-and-compliance)。

## Obsidian 整合與舊資料

Vault 路徑依序由環境變數 `THOUGHTDROP_VAULT`、設定檔 `~/.config/thoughtdrop/vault-path`（第一行寫路徑，Finder 開啟的 App 也讀得到）決定；都沒設定時預設 `~/Documents/ObsidianVault`，且該資料夾必須是 Obsidian vault（含 `.obsidian`）。App 的所有檔案限定在其中的 `ThoughtDrop/`。Markdown 會附上 YAML 屬性與 `thoughtdrop` 標籤，內部來源以完整 vault 相對路徑的 `[[wikilinks]]` 連結。「開啟知識庫／最近回顧」會直接用 Obsidian 開啟。

首次啟動新版會把舊的 `~/Documents/ThoughtDrop` **複製**進 vault，舊檔保留不刪除；遇到同名不同內容即停止並提示，不蓋掉目的地資料。成功後寫入搬移標記，之後不再重複匯入舊檔。找不到 vault 會提示錯誤，不會悄悄改寫到另一處。原 vault 的其他資料夾不會修改。

維護命令（需先建置）：

```sh
swift run ThoughtDropTools prepare-vault
swift run ThoughtDropTools check-codex
swift run ThoughtDropTools check-claude
```

`check-*` 會消耗一次校正加一次整理的用量，只使用程式內的虛構測試文字，檔案驗證在暫存目錄進行。
