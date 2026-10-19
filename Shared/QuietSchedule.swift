import Foundation

/// Hours when this device stays completely off the network (e.g. a work laptop during work time).
struct QuietSchedule: Codable, Equatable {
    /// Calendar weekday numbers: 1 = Sunday … 7 = Saturday.
    var days: Set<Int>
    /// Minutes after midnight. `end <= start` means the window runs past midnight.
    var start: Int
    var end: Int

    static let `default` = QuietSchedule(days: [2, 3, 4, 5, 6], start: 9 * 60, end: 17 * 60)

    /// The quiet window that contains `date`, if any. An overnight window belongs to the day it starts on.
    func window(containing date: Date, calendar: Calendar = .current) -> DateInterval? {
        guard start != end else { return nil }
        let today = calendar.startOfDay(for: date)
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  days.contains(calendar.component(.weekday, from: day)),
                  let begins = calendar.date(byAdding: .minute, value: start, to: day),
                  let ends = calendar.date(byAdding: .minute, value: end <= start ? end + 24 * 60 : end, to: day)
            else { continue }
            if date >= begins && date < ends { return DateInterval(start: begins, end: ends) }
        }
        return nil
    }

    /// Bonjour TXT form, e.g. "2,3,4,5,6|540|1020", so other devices know when not to call.
    var txtValue: String { "\(days.sorted().map(String.init).joined(separator: ","))|\(start)|\(end)" }

    init(days: Set<Int>, start: Int, end: Int) {
        self.days = days
        self.start = start
        self.end = end
    }

    init?(txtValue: String) {
        let parts = txtValue.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let start = Int(parts[1]), let end = Int(parts[2]) else { return nil }
        self.init(days: Set(parts[0].split(separator: ",").compactMap { Int($0) }), start: start, end: end)
    }

    static let dayNames = [1: "أحد", 2: "إثنين", 3: "ثلاثاء", 4: "أربعاء", 5: "خميس", 6: "جمعة", 7: "سبت"]
    /// Display order starting with Sunday.
    static let dayOrder = [1, 2, 3, 4, 5, 6, 7]
}

/// Why CoShare is (or isn't) on the network right now.
enum NetworkPresence: Equatable {
    case online
    /// The person pressed pause.
    case paused
    /// Inside a scheduled quiet window.
    case quiet(until: Date)

    var isOnline: Bool { self == .online }
}
