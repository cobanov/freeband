import Foundation

/// How long the band's battery will last, from the battery readings Freeband already keeps (one
/// per session). Pure; the Band screen shows the result.
enum BatteryEstimate {
    /// Needs this much of a discharge to say anything.
    static let minHours = 12.0
    static let minDrop = 3

    /// Days left at the rate of the latest discharge, or nil when there is too little to go on.
    /// `readings`: oldest first. The latest discharge is the run of readings since the level last
    /// went up (a charge); only it is used.
    static func daysLeft(_ readings: [(at: Date, level: Int)]) -> Double? {
        guard var last = readings.last else { return nil }
        var first = last
        for reading in readings.dropLast().reversed() {
            if reading.level < first.level { break }  // the level rose after this reading: a charge
            first = reading
        }
        last = readings[readings.count - 1]
        let hours = last.at.timeIntervalSince(first.at) / 3600
        let drop = first.level - last.level
        guard hours >= minHours, drop >= minDrop else { return nil }
        return Double(last.level) / (Double(drop) / hours) / 24
    }
}
