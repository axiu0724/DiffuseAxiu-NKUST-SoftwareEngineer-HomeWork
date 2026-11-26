import Foundation

/// 連續播放的決策邏輯（純資料、沒有網路請求，方便測試）。
///
/// 為什麼需要它：用 `PUT /me/player/play` 送出一串 uris 播放，播完最後一首後 Spotify 會進入 autoplay 推薦歌曲。
/// 而且一次能送的 uris 有限。做法如下：
/// 1. 先送出一段 window（例如 100 首）。
/// 2. 播到 window 的**最後一首**時，再用 `POST /me/player/queue` 一首一首把後面的歌補進佇列，
///    並保持「後面已排好的歌 ≥ lookahead 首」。
///    不能更早補，因為佇列裡的歌會插在 window 剩下的歌前面，順序就亂了。
/// 3. 整份清單播完時暫停，不讓 autoplay 接手。
public struct SequencePlan: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// 正在照順序播放
        case playing
        /// 使用者在其他地方換了歌，已停止接管
        case detached
        /// 全部播完
        case finished
    }

    public enum Action: Sendable, Equatable {
        case play([String])
        case enqueue(String)
        case pause
    }

    /// 剛送出 play 之後，Spotify 回報的狀態可能還是舊歌。
    /// 在確認開始播放之前，最多容忍這麼多次對不上的觀察。
    public static let startupGraceObservations = 5

    public let uris: [String]
    public let lookahead: Int
    /// 用 play 送出的範圍 `windowStart..<windowEnd`
    public let windowStart: Int
    public let windowEnd: Int
    /// 已送到播放器（play 或 queue）的範圍終點（不含）
    public private(set) var queuedEnd: Int
    public private(set) var currentIndex: Int
    public private(set) var status: Status
    public private(set) var hasConfirmedStart = false
    private var unmatchedStartupObservations = 0

    /// 從第 `index` 首開始播放，回傳計畫和要執行的動作。
    public static func start(uris: [String], at index: Int, windowSize: Int, lookahead: Int = 2) -> (SequencePlan, [Action]) {
        precondition(uris.indices.contains(index), "index 超出範圍")
        let end = min(index + max(windowSize, 1), uris.count)
        let plan = SequencePlan(
            uris: uris, lookahead: max(lookahead, 1),
            windowStart: index, windowEnd: end, queuedEnd: end,
            currentIndex: index, status: .playing
        )
        return (plan, [.play(Array(uris[index..<end]))])
    }

    private init(uris: [String], lookahead: Int, windowStart: Int, windowEnd: Int, queuedEnd: Int, currentIndex: Int, status: Status) {
        self.uris = uris
        self.lookahead = lookahead
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.queuedEnd = queuedEnd
        self.currentIndex = currentIndex
        self.status = status
    }

    public var isLastTrack: Bool { currentIndex == uris.count - 1 }

    /// 每次輪詢到播放狀態時呼叫，回傳需要執行的動作。
    public mutating func observe(currentURI: String?) -> [Action] {
        guard status == .playing, let currentURI else { return [] }

        guard let index = locate(currentURI) else {
            if !hasConfirmedStart {
                unmatchedStartupObservations += 1
                if unmatchedStartupObservations >= Self.startupGraceObservations { status = .detached }
                return []
            }
            if isLastTrack {
                // 最後一首播完，Spotify 開始播推薦歌曲 → 暫停
                status = .finished
                return [.pause]
            }
            status = .detached
            return []
        }

        hasConfirmedStart = true
        currentIndex = index
        return refill()
    }

    /// 在已送出的範圍內找出目前這首歌的位置。
    /// 先往後找（正常播放），找不到再往前找（使用者按了上一首），避免同一首歌重複出現時對錯位置。
    private func locate(_ uri: String) -> Int? {
        if let i = uris[currentIndex..<queuedEnd].firstIndex(of: uri) { return i }
        return uris[windowStart..<currentIndex].lastIndex(of: uri)
    }

    private mutating func refill() -> [Action] {
        guard currentIndex >= windowEnd - 1 else { return [] }
        var actions: [Action] = []
        while queuedEnd < uris.count, queuedEnd - 1 - currentIndex < lookahead {
            actions.append(.enqueue(uris[queuedEnd]))
            queuedEnd += 1
        }
        return actions
    }
}
