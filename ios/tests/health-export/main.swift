import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let namespace = UUID(uuidString: "A75B0BF5-4F98-4FF1-B70D-EA7A1993F44E")!
let start = Date(timeIntervalSince1970: 1_700_000_000)
func sample(_ value: Int) -> HealthExportSample {
    HealthExportSample(namespace: namespace, kind: .steps, start: start, end: start.addingTimeInterval(60), value: value)
}
func scope(_ authoritative: Bool) -> HealthExportScope {
    HealthExportScope(namespace: namespace, kind: .steps, start: start, end: start.addingTimeInterval(60), authoritative: authoritative)
}

let first = try HealthExportPlanner.reconcile(samples: [sample(10)], entries: [], scopes: [scope(true)])
check(first.changes == [.save(sample(10), version: 1)], "new sample")
let retry = try HealthExportPlanner.reconcile(samples: [sample(10)], entries: first.entries, scopes: [scope(true)])
check(retry.changes == first.changes, "interrupted save must keep its version")
var saved = first.entries
saved[0].state = .saved
let unchanged = try HealthExportPlanner.reconcile(samples: [sample(10)], entries: saved, scopes: [scope(true)])
check(unchanged.changes.isEmpty, "unchanged sample must not be resent")
let corrected = try HealthExportPlanner.reconcile(samples: [sample(12)], entries: saved, scopes: [scope(true)])
check(corrected.changes == [.save(sample(12), version: 2)], "correction increments version")
let partial = try HealthExportPlanner.reconcile(samples: [], entries: saved, scopes: [scope(false)])
check(partial.changes.isEmpty, "incomplete source must not delete")
let removed = try HealthExportPlanner.reconcile(samples: [], entries: saved, scopes: [scope(true)])
check(removed.changes == [.delete(identifier: sample(10).identifier, kind: .steps)], "authoritative removal")
let resumed = try HealthExportPlanner.reconcile(samples: [], entries: removed.entries, scopes: [scope(true)])
check(resumed.changes == removed.changes, "interrupted deletion must retry")
var suppressed = saved
suppressed[0].state = .suppressed
let deletedLocally = try HealthExportPlanner.reconcile(samples: [sample(10)], entries: suppressed, scopes: [scope(true)])
check(deletedLocally.changes.isEmpty, "local deletion suppresses re-export")
check(!sample(10).identifier.contains(":"), "identifier contains no MAC address")
var minutes = MinuteSeries(day: DayKey(index: 20_000), tzOffsetMinutes: 120)
minutes.steps[0] = 15
minutes.heartRate[0] = 75
minutes.steps[1] = 0
minutes.heartRate[1] = 255
check(HealthExportMapping.minutes(minutes, namespace: namespace, eligible: false).isEmpty, "ineligible or demo input")
let mapped = HealthExportMapping.minutes(minutes, namespace: namespace, eligible: true)
check(mapped.count == 2, "only valid nonzero values are mapped")
check(mapped[0].start == DayKey(index: 20_000).start(offsetMinutes: 120), "source offset determines instant")
check(mapped[0].end.timeIntervalSince(mapped[0].start) == 60, "steps cover one minute")
check(mapped[1].kind == .heartRate && mapped[1].start == mapped[1].end, "heart rate is a point sample")
let stages = [StageSegment(start: start, minutes: 2, stage: .light),
              StageSegment(start: start.addingTimeInterval(120), minutes: 1, stage: .unknown)]
let sleep = HealthExportMapping.sleep(stages, bed: start, wake: start.addingTimeInterval(180),
                                      namespace: namespace, eligible: true)
check(sleep.count == 2 && sleep[1].start == start.addingTimeInterval(60), "sleep stages use stable minute slots")
do {
    _ = try HealthExportPlanner.reconcile(samples: [sample(10), sample(12)], entries: [], scopes: [scope(true)])
    fatalError("conflicting samples must not share an identifier")
} catch HealthExportPlanner.PlanError.duplicateIdentifier { }
do {
    _ = try HealthExportPlanner.reconcile(samples: [], entries: saved, scopes: [scope(true), scope(true)])
    fatalError("overlapping scopes must be rejected")
} catch HealthExportPlanner.PlanError.overlappingScopes { }
let otherNamespace = UUID()
let unrelatedScope = HealthExportScope(namespace: otherNamespace, kind: .steps, start: start,
                                       end: start.addingTimeInterval(60), authoritative: true)
let unrelated = try HealthExportPlanner.reconcile(samples: [], entries: saved, scopes: [unrelatedScope])
check(unrelated.changes.isEmpty, "a different band must not delete this band's samples")
let sleepScope = HealthExportScope(namespace: namespace, kind: .sleep, start: start,
                                   end: start.addingTimeInterval(180), authoritative: true)
let initialSleep = try HealthExportPlanner.reconcile(samples: sleep, entries: [], scopes: [sleepScope])
var savedSleep = initialSleep.entries
for i in savedSleep.indices { savedSleep[i].state = .saved }
let revisedSleep = [HealthExportSample(namespace: namespace, kind: .sleep, start: start,
                                      end: start.addingTimeInterval(60), value: Int(StageKind.deep.rawValue))]
let revisedPlan = try HealthExportPlanner.reconcile(samples: revisedSleep, entries: savedSleep, scopes: [sleepScope])
check(revisedPlan.changes.contains(.save(revisedSleep[0], version: 2)), "changed sleep stage updates its slot")
check(revisedPlan.changes.contains(.delete(identifier: sleep[1].identifier, kind: .sleep)), "shortened sleep removes only the missing slot")
print("Health export planner checks passed")
