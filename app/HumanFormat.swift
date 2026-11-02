import Foundation

/// Presentation only: persisted measurements and export receipts retain their original units.
enum HumanFormat {
    static func size(_ bytes: Int64, locale: Locale) -> String {
        guard bytes >= 0 else { return "—" }
        let russian = locale.language.languageCode?.identifier == "ru"
        let giga = bytes >= 1_000_000_000
        let unit = giga ? (russian ? "ГБ" : "GB") : (russian ? "МБ" : "MB")
        let divisor = giga ? 1_000_000_000.0 : 1_000_000.0
        if bytes > 0 && bytes < 10_000 { return "< " + (0.01).formatted(.number.locale(locale)) + " " + unit }
        return (Double(bytes) / divisor).formatted(.number.precision(.fractionLength(0...2)).locale(locale)) + " " + unit
    }

    static func duration(seconds: Double?, locale: Locale) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) else { return "—" }
        let total = Int64(seconds.rounded(.down))
        let ru = locale.language.languageCode?.identifier == "ru"
        let values = [(total / 86400, ru ? "д" : "d"), (total / 3600 % 24, ru ? "ч" : "h"),
                      (total / 60 % 60, ru ? "мин" : "min"), (total % 60, ru ? "с" : "s")]
        // Preserve zero components inside the duration so the exact uptime remains readable.
        let first = values.firstIndex(where: { $0.0 > 0 }) ?? 3
        return values[first...].map { String($0.0) + " " + $0.1 }.joined(separator: " ")
    }
}
