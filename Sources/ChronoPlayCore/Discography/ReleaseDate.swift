import Foundation

/// Spotify 的發行日期。精度可能只有年（"1998"）或年月（"1998-05"）。
///
/// 比較規則：缺少的月、日補成 1，所以 "1998" 視為 1998-01-01。
/// 同一天時精度高的排前面（"1998-01-01" 早於 "1998"），因為只寫年份的通常是資料不完整的舊作。
/// 無法解析的日期（例如 "0000"）排在最後。
public struct ReleaseDate: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int?
    public let month: Int?
    public let day: Int?
    public let precision: ReleaseDatePrecision

    public init(string: String, precision: ReleaseDatePrecision) {
        let parts = string.split(separator: "-").map { Int($0) }
        let y = parts.first.flatMap { $0 }
        self.year = (y ?? 0) > 0 ? y : nil
        self.month = parts.count > 1 && precision != .year ? parts[1] : nil
        self.day = parts.count > 2 && precision == .day ? parts[2] : nil
        self.precision = precision
    }

    public var isKnown: Bool { year != nil }

    private var precisionRank: Int {
        switch precision {
        case .day: 0
        case .month: 1
        case .year: 2
        }
    }

    private var sortKey: (Int, Int, Int, Int) {
        (year ?? Int.max, month ?? 1, day ?? 1, precisionRank)
    }

    public static func < (lhs: ReleaseDate, rhs: ReleaseDate) -> Bool {
        lhs.sortKey < rhs.sortKey
    }

    /// 顯示用文字："1998-05-01"、"1998-05"、"1998"，未知為 "未知"。
    public var description: String {
        guard let year else { return "未知" }
        var text = String(format: "%04d", year)
        if let month { text += String(format: "-%02d", month) }
        if let day { text += String(format: "-%02d", day) }
        return text
    }

    /// 依年份分段時的標題
    public var yearText: String {
        year.map(String.init) ?? "日期未知"
    }
}
