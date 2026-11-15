import CryptoKit
import Foundation

/// JSON bodies from docs/API.md (schema freeband.v1), shared by webhooks, the hub and export.
enum Payload {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    struct Device {
        let id: UUID
        let name: String
        let model: String

        init(_ band: Band) {
            id = band.id
            name = band.name
            model = band.model
        }

        init(id: UUID, name: String, model: String) {
            self.id = id
            self.name = name
            self.model = model
        }
    }

    static func sample(_ d: SampleDraft) -> [String: Any] {
        var out: [String: Any] = ["type": d.kind, "ts": iso.string(from: d.ts)]
        switch d.kind {
        case "battery":
            out["level"] = d.level
        default:
            out["steps"] = d.steps
            out["calories"] = d.calories
            out["heart_rate"] = d.heartRate
            out["standing_hours"] = d.standingHours
        }
        return out
    }

    // MARK: health records (docs/API.md: minute, sleep, score)
    //
    // Extra record types in the same "samples" array, unique per (device.id, type, ts). The hub
    // rejects a whole body when one field is out of range, so values outside the documented
    // ranges are left out (optional fields) or sent as null (nullable fields), never as-is.

    /// One record per non-empty minute (steps > 0 or any reading); `ts` is the minute's start (UTC).
    static func minuteRecords(_ s: MinuteSeries) -> [[String: Any]] {
        (0 ..< MinuteSeries.slots).compactMap { i -> [String: Any]? in
            let steps = s.steps[i].flatMap { (0 ... 1000).contains($0) ? $0 : nil } ?? 0
            var r: [String: Any] = ["type": "minute", "ts": iso.string(from: s.time(ofMinute: i)), "steps": steps]
            if let v = ValidRange.hr(s.heartRate[i]) { r["heart_rate"] = v }
            if let v = ValidRange.spo2(s.spo2[i]) { r["spo2"] = v }
            if let v = s.stress[i], ValidRange.stress.contains(v) { r["stress"] = v }
            if let v = s.kcal[i], (0 ... 100).contains(v) { r["active_calories"] = v }
            if let v = s.distance[i], (0 ... 1000).contains(v) { r["distance_m"] = v }
            return steps > 0 || r.count > 3 ? r : nil
        }
    }

    /// One sleep session; `ts` is the bed time. Nil when the session can't satisfy the contract
    /// (wake not after bed, or longer than 24 hours).
    static func sleepRecord(_ d: SleepDraft) -> [String: Any]? {
        let span = d.wakeTime.timeIntervalSince(d.bedTime)
        guard span >= 60, span <= 86_400 else { return nil }
        let m = SleepMetricsCalc.compute(d.input, minutes: [], awakeHRMean: nil)
        let total = Int(span / 60)

        func minutes(_ v: Double?, _ fallback: Int?) -> Int { min(max(Int((v ?? Double(fallback ?? 0)).rounded()), 0), 1440) }
        var parts = [("deep", minutes(m.deepMinutes, d.deepMinutes)), ("light", minutes(m.lightMinutes, d.lightMinutes)),
                     ("rem", minutes(m.remMinutes, d.remMinutes)), ("awake", minutes(m.awakeMinutes, d.awakeMinutes))]
        if parts.reduce(0, { $0 + $1.1 }) > 1440 { parts = parts.map { ($0.0, 0) } }

        var stages: [[Any]] = []
        var cursor = 0
        for seg in d.segments.sorted(by: { $0.start < $1.start }) {
            let name: String
            switch seg.stage {
            case .deep: name = "deep"
            case .light: name = "light"
            case .rem: name = "rem"
            case .awake: name = "awake"
            case .notSleep, .unknown: continue
            }
            let offset = max(Int(seg.start.timeIntervalSince(d.bedTime) / 60), cursor)
            let duration = min(seg.minutes, total - offset)
            guard duration >= 1, stages.count < 1440 else { continue }
            stages.append([offset, name, duration])
            cursor = offset + duration
        }

        let efficiency = m.efficiency ?? (m.inBedMinutes > 0 ? m.totalSleepMinutes / m.inBedMinutes : 0)
        var r: [String: Any] = [
            "type": "sleep", "ts": iso.string(from: d.bedTime), "end": iso.string(from: d.wakeTime), "is_nap": d.isNap,
            "minutes": Dictionary(uniqueKeysWithValues: parts),
            "wake_count": min(max(m.wakeCount ?? d.wakeCount ?? 0, 0), 255),
            "efficiency": min(max(Int((efficiency * 100).rounded()), 0), 100),
            "stages": stages,
            "hr_min": ValidRange.hr(m.hrMinimum.map { Int($0.rounded()) }) ?? NSNull(),
        ]
        let spo2Avg = m.spo2Average.flatMap { $0.isFinite && (70 ... 100).contains($0) ? ($0 * 10).rounded() / 10 : nil }
        let spo2Min = ValidRange.spo2(m.spo2Minimum.map { Int($0.rounded()) })
        r["spo2_avg"] = spo2Avg ?? NSNull()
        r["spo2_min"] = spo2Min.flatMap { v in spo2Avg.map { Double(v) <= $0 ? v : nil } ?? v } ?? NSNull()
        if let hrv = HRV.nightly(d.rr, bedTime: d.bedTime, wakeTime: d.wakeTime).result?.rmssd, hrv.isFinite, (1 ... 300).contains(hrv) {
            r["hrv_rmssd"] = (hrv * 10).rounded() / 10
        }
        return r
    }

    /// The day's three scores; `ts` is local midnight of `date` (UTC instant).
    static func scoreRecord(_ s: DailyScore, tzOffsetMinutes: Int) -> [String: Any] {
        func clamp(_ v: Int?, _ range: ClosedRange<Int>) -> Any { v.map { min(max($0, range.lowerBound), range.upperBound) } ?? NSNull() }
        func finite(_ v: Double?, _ range: ClosedRange<Double>, digits: Double = 10) -> Any {
            guard let v, v.isFinite, range.contains(v) else { return NSNull() }
            return (v * digits).rounded() / digits
        }
        return [
            "type": "score", "ts": iso.string(from: s.dayKey.start(offsetMinutes: tzOffsetMinutes)), "date": s.dayKey.string,
            "sleep": clamp(s.sleepScore, 0 ... 100), "recovery": clamp(s.recoveryScore, 0 ... 100),
            "strain": s.strain.map { finite(min(max($0, 0), 21), 0 ... 21) } ?? NSNull(),
            "rhr": ValidRange.hr(s.rhr.map { Int($0.rounded()) }) ?? NSNull(),
            "hrv_rmssd": finite(s.hrv, 1 ... 300),
            "confidence": ["sleep": level(s.sleepConfidence), "recovery": level(s.recoveryConfidence),
                           "strain": level(s.strainConfidence)],
            "contributors": s.result.map(contributors) ?? [],
            "algo": "freeband-score/\(s.algoVersion)",
        ]
    }

    private static func level(_ raw: String) -> String { ConfidenceLevel(rawValue: raw)?.rawValue ?? "none" }

    /// Sleep and recovery contributors in the hub's shape. Fractions are sent as percentages.
    static func contributors(_ r: DayScoreResult) -> [[String: Any]] {
        func number(_ v: Double?, scale: Double = 1) -> Any {
            guard let v, v.isFinite else { return NSNull() }
            return (v * scale * 10).rounded() / 10
        }
        func subscore(_ v: Double?) -> Any { v.flatMap { $0.isFinite ? min(max(Int($0.rounded()), 0), 100) : nil } ?? NSNull() }
        var out: [[String: Any]] = []
        for c in r.sleep.contributors {
            let (unit, scale): (String, Double) = switch c.name {
            case .duration, .restfulness, .regularity: ("min", 1)
            case .efficiency, .deep, .rem, .hrDip: ("%", 100)
            }
            out.append(["score": "sleep", "key": c.name.rawValue, "weight": min(max(Int(c.weight.rounded()), 0), 100),
                        "value": number(c.value, scale: scale), "unit": unit, "subscore": subscore(c.subscore),
                        "baseline": number(c.baseline, scale: scale)])
        }
        for c in r.recovery.contributors {
            let unit = switch c.name {
            case .hrv: "ms"
            case .restingHR: "bpm"
            case .sleep, .strain: ""
            }
            var row: [String: Any] = ["score": "recovery", "key": c.name.rawValue,
                                      "weight": min(max(Int(c.weight.rounded()), 0), 100),
                                      "value": number(c.today), "subscore": subscore(c.subscore),
                                      "baseline": number(c.baseline?.median)]
            if !unit.isEmpty { row["unit"] = unit }
            out.append(row)
        }
        return Array(out.prefix(32))
    }

    /// Bodies of at most `limit` entries each (the hub takes 5000 samples and 512 KB per body):
    /// the samples and the first records go in the first body, the rest follow.
    static func bodies(event: String, device: Device, samples: [SampleDraft], records: [[String: Any]],
                       limit: Int = 4000, now: Date = Date()) -> [Data] {
        var out: [Data] = []
        var remaining = records[...]
        let first = max(limit - samples.count, 0)
        out.append(body(event: event, device: device, samples: samples, records: Array(remaining.prefix(first)), now: now))
        remaining = remaining.dropFirst(first)
        while !remaining.isEmpty {
            out.append(body(event: event, device: device, samples: [], records: Array(remaining.prefix(limit)), now: now))
            remaining = remaining.dropFirst(limit)
        }
        return out
    }

    static func body(event: String, device: Device, samples: [SampleDraft], records: [[String: Any]] = [],
                     now: Date = Date()) -> Data {
        let calendar = Calendar.current
        let today = samples.filter { $0.kind == "live" && calendar.isDate($0.ts, inSameDayAs: now) }
        let latest = today.max { $0.ts < $1.ts }
        let lastHeart = today.filter { $0.heartRate > 10 }.max { $0.ts < $1.ts }
        let battery = samples.filter { $0.kind == "battery" }.max { $0.ts < $1.ts }

        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"

        var summary: [String: Any] = ["date": day.string(from: now)]
        if let latest {
            summary["steps"] = latest.steps
            summary["calories"] = latest.calories
        }
        if let lastHeart { summary["heart_rate_last"] = lastHeart.heartRate }
        if let battery { summary["battery"] = battery.level }

        let body: [String: Any] = [
            "schema": "freeband.v1",
            "event": event,
            "device": ["id": device.id.uuidString, "name": device.name, "model": device.model,
                       "app_version": appVersion, "tz": TimeZone.current.identifier],
            "sent_at": iso.string(from: now),
            "summary": summary,
            "samples": samples.sorted { $0.ts < $1.ts }.map(sample) + records,
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }
}

/// Delivers signed webhook requests (header names from docs/API.md).
enum WebhookSender {
    static func newSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "whsec_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func signature(_ body: Data, secret: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        return "sha256=" + mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns a short status for the settings screen, e.g. "200" or the error.
    static func deliver(_ body: Data, event: String, to url: URL, secret: String) async -> String {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(event, forHTTPHeaderField: "X-Freeband-Event")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Freeband-Delivery")
        request.setValue(signature(body, secret: secret), forHTTPHeaderField: "X-Freeband-Signature")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return "\((response as? HTTPURLResponse)?.statusCode ?? 0)"
        } catch {
            return error.localizedDescription
        }
    }
}

/// CSV and JSON exports of everything stored on the phone.
enum Exporter {
    static func write(csv samples: [Sample], bands: [Band]) throws -> URL {
        let names = Dictionary(uniqueKeysWithValues: bands.map { ($0.id, $0.name) })
        var lines = ["device_id,device_name,type,ts,steps,calories,heart_rate,standing_hours,battery"]
        for s in samples.sorted(by: { $0.ts < $1.ts }) {
            let name = (names[s.bandID] ?? "").replacingOccurrences(of: "\"", with: "\"\"")
            lines.append([s.bandID.uuidString, "\"\(name)\"", s.kind, Payload.iso.string(from: s.ts),
                          "\(s.steps)", "\(s.calories)", "\(s.heartRate)", "\(s.standingHours)", "\(s.level)"]
                .joined(separator: ","))
        }
        return try save(Data(lines.joined(separator: "\n").utf8), ext: "csv")
    }

    static func write(json samples: [Sample], bands: [Band]) throws -> URL {
        let body: [String: Any] = [
            "schema": "freeband.v1",
            "exported_at": Payload.iso.string(from: Date()),
            "devices": bands.map { ["id": $0.id.uuidString, "name": $0.name, "model": $0.model] },
            "samples": samples.sorted { $0.ts < $1.ts }.map { s -> [String: Any] in
                var row = Payload.sample(SampleDraft(sample: s))
                row["device_id"] = s.bandID.uuidString
                return row
            },
        ]
        return try save(try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]), ext: "json")
    }

    private static func save(_ data: Data, ext: String) throws -> URL {
        let day = Date().formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("freeband-\(day).\(ext)")
        try data.write(to: url, options: .completeFileProtection)
        return url
    }
}

extension SampleDraft {
    init(sample s: Sample) {
        self.init(kind: s.kind, ts: s.ts, steps: s.steps, calories: s.calories, heartRate: s.heartRate,
                  standingHours: s.standingHours, level: s.level)
    }
}
