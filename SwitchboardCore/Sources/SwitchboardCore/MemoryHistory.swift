import Foundation

/// MCP server memory per owner over the last few minutes. It is kept in memory only.
public struct MemoryHistory: Sendable {
  public struct Sample: Equatable, Sendable {
    public var date: Date
    public var footprints: [Owner: UInt64]

    public init(date: Date, footprints: [Owner: UInt64]) {
      self.date = date
      self.footprints = footprints
    }
  }

  /// One owner's memory in one sample, ready to stack. `segment` numbers the runs of samples
  /// without a gap, so a chart can draw each run on its own and never across a gap.
  public struct Point: Equatable, Identifiable, Sendable {
    public var segment: Int
    public var date: Date
    public var owner: Owner
    public var footprint: UInt64

    public var id: String {
      "\(segment)|\(date.timeIntervalSinceReferenceDate)|\(owner)"
    }
  }

  public static let defaultSpan: TimeInterval = 600
  /// Twice the 30 seconds between samples while the window is closed, so those samples join into
  /// one run and only a real pause, such as sleep, leaves a gap.
  public static let defaultMaximumGap: TimeInterval = 60

  public let span: TimeInterval
  /// Two samples further apart than this belong to different segments.
  public let maximumGap: TimeInterval
  public private(set) var samples: [Sample] = []

  public init(span: TimeInterval = defaultSpan, maximumGap: TimeInterval = defaultMaximumGap) {
    self.span = span
    self.maximumGap = maximumGap
  }

  public mutating func append(_ report: MemoryReport, at date: Date) {
    let footprints = Dictionary(
      report.ownerTotals.map { ($0.owner, $0.footprint) }, uniquingKeysWith: +)
    append(Sample(date: date, footprints: footprints))
  }

  /// Adds `sample` and drops samples older than `span` before it. A sample dated before the last
  /// one means the clock moved back, so the samples after it are dropped first.
  public mutating func append(_ sample: Sample) {
    samples.removeAll { $0.date > sample.date || sample.date.timeIntervalSince($0.date) > span }
    samples.append(sample)
  }

  /// Runs of samples in which no two neighbours are more than `maximumGap` apart.
  public var segments: [[Sample]] {
    var runs: [[Sample]] = []
    for sample in samples {
      if let last = runs.last?.last, sample.date.timeIntervalSince(last.date) <= maximumGap {
        runs[runs.count - 1].append(sample)
      } else {
        runs.append([sample])
      }
    }
    return runs
  }

  /// Every owner in the history: Claude Desktop first, then sessions by process ID, then orphans.
  public var owners: [Owner] {
    Set(samples.flatMap(\.footprints.keys)).sorted { Self.order($0) < Self.order($1) }
  }

  /// One point per sample for each owner present anywhere in that sample's segment, with zero
  /// where the owner had nothing, in the order of `owners` so stacking stays stable.
  public var points: [Point] {
    let ordered = owners
    var points: [Point] = []
    for (index, run) in segments.enumerated() {
      let present = Set(run.flatMap(\.footprints.keys))
      for sample in run {
        for owner in ordered where present.contains(owner) {
          points.append(
            Point(
              segment: index, date: sample.date, owner: owner,
              footprint: sample.footprints[owner] ?? 0))
        }
      }
    }
    return points
  }

  private static func order(_ owner: Owner) -> (Int, Int32) {
    switch owner {
    case .desktop: (0, 0)
    case .session(let id, _): (1, id)
    case .orphaned: (2, 0)
    }
  }
}
