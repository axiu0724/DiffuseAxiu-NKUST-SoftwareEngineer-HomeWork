# ChronoPlay

國立高雄科技大學「軟體工程」課程作業。

一個支援 Liquid Glass 的 macOS app，串接 Spotify 官方 Web API。它把藝人的所有作品**從最舊到最新**排好，然後一路連續播放。

## 要解決的問題

在官方 Spotify app 裡，就算進入藝人的「所有歌曲」頁面，也沒辦法從最舊到最新連續播放。選一張專輯開始播，播完就直接跳到推薦歌曲。

ChronoPlay 的做法：

1. 抓出藝人的所有發行，包括專輯、單曲與 EP、客串作品。
2. 依發行日期由舊到新排序。同一首歌的原版、豪華版、重製版全部保留，各自排在自己的發行日期，每一列都會顯示所屬專輯和發行日期。
3. 遙控你的 Spotify 裝置（例如電腦上的官方 Spotify app），照順序一首接一首播下去，不會跳到推薦歌曲。全部播完後會自動暫停。

## 系統需求

- macOS 26 以上（Liquid Glass）
- Swift 6.2 以上。Command Line Tools 就夠，不需要 Xcode。
- Spotify Premium。遙控播放需要 Premium，而且 2026 年 2 月起，開發模式 app 的擁有者也必須是 Premium。

本專案不使用任何第三方套件。所有建置產物都在專案資料夾內的 `.build/` 和 `build/`，不會安裝到系統。

## 第一次設定：建立 Spotify 開發者 app

1. 到 [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) 登入，按 **Create app**。
2. 填入以下欄位：
   - App name / description：隨意填。
   - **Redirect URI**：`chronoplay://callback`（記得按 Add）。
   - **APIs used**：勾選 **Web API**。
3. 建立後，到 app 的 Settings 複製 **Client ID**。
4. 打開 ChronoPlay，把 Client ID 貼上，按「登入 Spotify」。

開發模式的 app 最多 5 位使用者。要讓其他帳號使用，必須先在 Dashboard 的 **User Management** 加入那個帳號。

## 建置與執行

```bash
# 編譯並打包成 build/ChronoPlay.app
scripts/bundle.sh

# 執行
open build/ChronoPlay.app
```

只想確認能不能編譯：

```bash
swift build
```

## 測試

```bash
# 執行全部單元測試
scripts/test.sh

# 只跑某一組或某一個測試
scripts/test.sh --filter SequencePlanTests
scripts/test.sh --filter "SequencePlanTests/queuesAtWindowEnd"
```

只有 Command Line Tools 時，`swift test` 找不到 Swift Testing 的 macro plugin，`scripts/test.sh` 會自動補上路徑。

## 使用方式

1. 在左側搜尋欄輸入藝人名稱，選擇藝人。
2. 等作品讀取完成。上方的按鈕可以切換要收錄的類型（專輯／單曲與 EP／客串）。
3. 開始播放有兩種方式：
   - 按「**從最舊播到最新**」。
   - 在任一首歌上雙擊，從那首開始播。
4. 底部的玻璃播放列會顯示目前播到第幾首、所屬專輯和發行日期。
5. 右上角可以選擇要在哪個裝置播放。如果找不到裝置，先打開官方 Spotify app。

## 運作原理

```
Sources/ChronoPlayCore/   不含 UI 的邏輯（有單元測試）
  Auth/                   PKCE 登入、Keychain 存 token、自動 refresh
  API/                    Spotify Web API client（處理 401、429、分頁）
  Discography/            抓作品、過濾客串曲目、依時間排序
  Playback/               連續播放引擎
Sources/ChronoPlay/       SwiftUI 介面（Liquid Glass）
Tests/ChronoPlayCoreTests/
```

### 連續播放引擎（`SequencePlan`）

Spotify 的 `PUT /me/player/play` 可以送出一串歌曲 URI。但這串歌播完後，Spotify 會進入 autoplay 推薦，而且一次能送的數量也有限。所以 ChronoPlay 自己管理播放順序：

1. 先送出一段歌曲（預設 100 首，可在設定調整）。
2. 每 3 秒查一次播放狀態。播到這一段的**最後一首**時，再用 `POST /me/player/queue` 把後面的歌一首一首補進佇列。
   - 不能更早補，因為佇列的歌會插在這一段剩下的歌前面，順序就亂了。
3. 整份清單播完後自動暫停，不讓推薦歌曲接手。
4. 如果你在官方 app 換了別的歌，ChronoPlay 會停止接管，播放列會出現「從第 N 首繼續」的按鈕。

### Spotify API 限制（2026 年 2 月起的開發模式）

- `GET /albums?ids=` 已移除，所以發行日期改從 `GET /artists/{id}/albums` 的回應取得。
- album 的 `album_group` 欄位已移除，所以「自己的作品」（`album,single`）和「客串」（`appears_on`）分兩次查。
- 搜尋一次最多 10 筆。

## 已知限制

- 要接上第一段之後的歌，ChronoPlay 必須保持開著。放在背景也可以。
- 播放中途如果在官方 app 手動加入佇列，那些歌會插進播放順序。
- 播放是遙控 Spotify Connect 裝置，所以聲音從那個裝置出來，不是從 ChronoPlay 本身。macOS 沒有 Spotify 原生播放 SDK。
- app 使用 ad-hoc 簽章，並把簽章身分固定為 bundle id（見 `scripts/bundle.sh`）。第一次讀取 Keychain 時 macOS 會詢問是否允許，選「永遠允許」後，之後重新打包就不會再問。代價是：任何用同一個 bundle id 簽章的程式都能讀到這組 token，這只適合開發與作業用途。
