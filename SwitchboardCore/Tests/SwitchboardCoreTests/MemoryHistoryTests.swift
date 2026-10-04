import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct MemoryHistoryTests {
  private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
  private let session = Owner.session(id: 42, project: "/work/alpha")

  private typealias Sample = MemoryHistory.Sample

  private func sample(_ seconds: TimeInterval, _ footprints: [Owner: UInt64]) -> Sample {
    MemoryHistory.Sample(date: start.addingTimeInterval(seconds), footprints: footprints)
  }

  @Test func dropsSamplesOlderThanTheSpan() {
    var history = MemoryHistory(span: 600)
    history.append(sample(0, [.desktop: 1]))
    history.append(sample(300, [.desktop: 2]))
    history.append(sample(601, [.desktop: 3]))
    #expect(history.samples.map { $0.footprints[.desktop] } == [2, 3])
  }

  @Test func clockMovingBackDropsLaterSamples() {
    var history = MemoryHistory()
    history.append(sample(0, [.desktop: 1]))
    history.append(sample(10, [.desktop: 2]))
    history.append(sample(5, [.desktop: 3]))
    #expect(history.samples.map { $0.footprints[.desktop] } == [1, 3])
  }

  @Test func splitsSegmentsOnlyWhereTheGapExceedsTheMaximum() {
    var history = MemoryHistory(maximumGap: 15)
    for seconds: TimeInterval in [0, 5, 20, 36, 41] {
      history.append(sample(seconds, [.desktop: 1]))
    }
    let offsets = history.segments.map { $0.map { $0.date.timeIntervalSince(start) } }
    #expect(offsets == [[0, 5, 20], [36, 41]])
  }

  @Test func pointsFillMissingOwnersWithZeroWithinASegmentOnly() {
    var history = MemoryHistory(maximumGap: 15)
    history.append(sample(0, [.desktop: 10]))
    history.append(sample(5, [.desktop: 11, session: 4]))
    history.append(sample(60, [.desktop: 12]))
    let points = history.points.map {
      "\($0.segment) \(Int($0.date.timeIntervalSince(start))) \($0.owner == .desktop ? "d" : "s") \($0.footprint)"
    }
    #expect(points == ["0 0 d 10", "0 0 s 0", "0 5 d 11", "0 5 s 4", "1 60 d 12"])
  }

  @Test func ownersAreOrderedDesktopSessionsThenOrphans() {
    var history = MemoryHistory()
    let other = Owner.session(id: 7, project: nil)
    history.append(sample(0, [.orphaned: 1, session: 1, .desktop: 1, other: 1]))
    #expect(history.owners == [.desktop, other, session, .orphaned])
  }

  @Test func appendingAReportUsesItsOwnerTotals() {
    let report = MemoryReport(
      usages: [
        ServerUsage(
          id: "a", owner: .desktop, label: "a", rowID: nil, matchedBy: nil, footprint: 3,
          processCount: 1),
        ServerUsage(
          id: "b", owner: .desktop, label: "b", rowID: nil, matchedBy: nil, footprint: 4,
          processCount: 1),
      ],
      issues: [])
    var history = MemoryHistory()
    history.append(report, at: start)
    #expect(history.samples == [MemoryHistory.Sample(date: start, footprints: [.desktop: 7])])
  }
}
