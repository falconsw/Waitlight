import Foundation

/// Visible copy. English source strings are the keys; `Localizable.xcstrings`
/// supplies Turkish.
enum L10n {
    private final class Token {}

    static var bundle: Bundle { Bundle(for: Token.self) }

    static func t(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle)
    }

    /// "4 min", "1 h 5 min": how long something has been going on.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 1 { return t("now") }
        if minutes < 60 { return t("\(minutes) min") }
        let hours = minutes / 60, rest = minutes % 60
        if hours < 24 { return rest == 0 ? t("\(hours) h") : t("\(hours) h \(rest) min") }
        let days = hours / 24, leftHours = hours % 24
        return leftHours == 0 ? t("\(days) d") : t("\(days) d \(leftHours) h")
    }

    /// When a window starts over: how long until then, and past a day the
    /// weekday and time too ("1 d 7 h · Sat 06:59"), which is how a week is read.
    static func reset(at date: Date, now: Date = Date()) -> String {
        let left = duration(date.timeIntervalSince(now))
        guard date.timeIntervalSince(now) >= 24 * 3600 else { return t("Resets in \(left)") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return t("Resets in \(left) · \(formatter.string(from: date))")
    }
}
