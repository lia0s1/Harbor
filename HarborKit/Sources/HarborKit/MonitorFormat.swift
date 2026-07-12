import Foundation

/// Compact, FinalShell-style number formatting for the monitoring panel.
/// Pure string functions — behavior pinned by unit tests.
public enum MonitorFormat {
    // MARK: - Sizes

    /// Compact size from a KiB count (the unit /proc and `df -kP` report):
    /// "812K", "113M", "2.7G", "1.2T".
    public static func sizeShort(kb: UInt64) -> String {
        sizeShort(bytes: Double(kb) * 1024)
    }

    /// Compact size from a byte count. Sub-KiB values round to "0K"–"1K";
    /// the panel never needs byte precision for sizes.
    public static func sizeShort(bytes: Double) -> String {
        var scaled = max(0, bytes) / 1024
        var unitIndex = 0
        // Promote when the value would *display* as 1024 (the %.0f rounding in
        // shortNumber): a raw 1023.5…<1024 rounds up to "1024" and must carry
        // into the next unit, else we render e.g. "1024M" instead of "1G".
        while scaled.rounded() >= 1024, unitIndex < sizeUnits.count - 1 {
            scaled /= 1024
            unitIndex += 1
        }
        return shortNumber(scaled) + sizeUnits[unitIndex]
    }

    private static let sizeUnits = ["K", "M", "G", "T", "P"]

    /// FinalShell-style table pair "2.7G/3.8G" (used/total, available/total…).
    public static func sizePair(_ firstKB: UInt64, _ secondKB: UInt64) -> String {
        sizeShort(kb: firstKB) + "/" + sizeShort(kb: secondKB)
    }

    // MARK: - Throughput

    /// "512 B/s", "65 KB/s", "1.2 MB/s" — for the ↑/↓ speed labels.
    public static func speed(bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value < 1024 { return String(format: "%.0f B/s", value) }
        var scaled = value / 1024
        var unitIndex = 0
        // Promote on the rounded display value (see sizeShort): avoids "1024 KB/s".
        while scaled.rounded() >= 1024, unitIndex < speedUnits.count - 1 {
            scaled /= 1024
            unitIndex += 1
        }
        return shortNumber(scaled) + " " + speedUnits[unitIndex]
    }

    private static let speedUnits = ["KB/s", "MB/s", "GB/s", "TB/s"]

    /// Ultra-compact tick label for sparkline y-axes: "0", "500B", "65K", "1.2M".
    public static func speedAxisLabel(bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value < 1 { return "0" }
        if value < 1024 { return String(format: "%.0fB", value) }
        var scaled = value / 1024
        var unitIndex = 0
        // Promote on the rounded display value (see sizeShort): avoids "1024M".
        while scaled.rounded() >= 1024, unitIndex < sizeUnits.count - 1 {
            scaled /= 1024
            unitIndex += 1
        }
        return shortNumber(scaled) + sizeUnits[unitIndex]
    }

    // MARK: - Time

    /// At most the two largest units, with labels following the active locale.
    public static func uptime(seconds: Double, locale: Locale = .current) -> String {
        // Defensive: converting a non-finite (inf/nan) or absurdly large Double
        // to Int is a hard trap that would crash the app. The parser already
        // rejects these, but never let the panel be the thing that crashes.
        let isChinese = locale.language.languageCode?.identifier == "zh"
        let day = isChinese ? "天" : "d"
        let hour = isChinese ? "小时" : "h"
        let minute = isChinese ? "分钟" : "m"
        let second = isChinese ? "秒" : "s"
        guard seconds.isFinite else { return "0 \(second)" }
        let total = Int(min(max(0, seconds), 9_000_000_000_000_000_000))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 {
            return hours > 0 ? "\(days) \(day) \(hours) \(hour)" : "\(days) \(day)"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours) \(hour) \(minutes) \(minute)" : "\(hours) \(hour)"
        }
        if minutes > 0 { return "\(minutes) \(minute)" }
        return "\(total) \(second)"
    }

    /// One decimal below 10 ms ("9.5 ms"), whole numbers above ("254 ms").
    public static func milliseconds(_ ms: Double) -> String {
        let value = max(0, ms)
        return value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
    }

    // MARK: - Ratios

    /// Whole percent, clamped to 0…100: "71%".
    public static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "0%" }
        return String(format: "%.0f%%", min(100, max(0, value)))
    }

    /// FinalShell-style load triple: "0.28, 0.31, 0.27".
    public static func loadAverage(_ load1: Double, _ load5: Double, _ load15: Double) -> String {
        [load1, load5, load15].map { v in
            v.isFinite ? String(format: "%.2f", v) : "0.00"
        }.joined(separator: ", ")
    }

    /// Top-process CPU column, FinalShell-style: "3.3", "0.3", "12" — one
    /// decimal below 10, whole numbers above, trailing ".0" dropped.
    public static func processCPU(_ percent: Double) -> String {
        guard percent.isFinite else { return "0" }
        return shortNumber(max(0, percent))
    }

    // MARK: - Helpers

    /// One decimal below 10 ("2.7", "9.5"), whole numbers above ("65", "113");
    /// trailing ".0" is dropped ("3.0" → "3").
    private static func shortNumber(_ value: Double) -> String {
        if value < 10 {
            let text = String(format: "%.1f", value)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
        return String(format: "%.0f", value)
    }
}
