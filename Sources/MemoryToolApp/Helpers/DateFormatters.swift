import Foundation

/// Date formatting utilities for displaying memory timestamps.
@MainActor
enum DateFormatters {
    /// Relative time formatter — "2 hours ago", "yesterday", etc.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Full date-time formatter — "2024-04-03 15:30"
    private static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// Returns a relative time string, e.g. "2 hours ago".
    static func relativeString(from date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Returns a full date-time string, e.g. "2024-04-03 15:30".
    static func fullString(from date: Date) -> String {
        fullFormatter.string(from: date)
    }
}
