import CoreMedia
import Testing

@testable import WakuVideoCore

private func t(_ seconds: Double) -> CMTime {
  CMTime(seconds: seconds, preferredTimescale: 600)
}

private func range(_ start: Double, _ end: Double) -> CMTimeRange {
  CMTimeRange(start: t(start), end: t(end))
}

private func run(_ frames: [(Int, Double)], range: CMTimeRange) -> [TrimTimeline<Int>.Output] {
  var timeline = TrimTimeline<Int>(range: range)
  var outputs: [TrimTimeline<Int>.Output] = []
  for (frame, time) in frames where !timeline.isFinished {
    outputs += timeline.push(frame, at: t(time))
  }
  return outputs + timeline.finish()
}

private func output(_ frame: Int, _ time: Double) -> TrimTimeline<Int>.Output {
  TrimTimeline.Output(frame: frame, time: t(time))
}

struct TrimTimelineTests {
  @Test func placesFrameShownAtStartOnStart() {
    let outputs = run([(0, 0), (1, 0.5), (2, 2), (3, 2.1), (4, 4)], range: range(1.2, 3))
    #expect(outputs == [output(1, 1.2), output(2, 2), output(3, 2.1), output(3, 3)])
  }

  @Test func frameExactlyAtStartIsKeptAtItsTime() {
    let outputs = run([(0, 0), (1, 1), (2, 2)], range: range(1, 3))
    #expect(outputs == [output(1, 1), output(2, 2), output(2, 3)])
  }

  @Test func frameExactlyAtEndIsExcluded() {
    let outputs = run([(0, 0), (1, 1), (2, 2)], range: range(0.5, 2))
    #expect(outputs == [output(0, 0.5), output(1, 1), output(1, 2)])
  }

  @Test func stopsAtFirstFrameAtOrAfterEnd() {
    var timeline = TrimTimeline<Int>(range: range(0, 1))
    _ = timeline.push(0, at: t(0))
    #expect(timeline.push(1, at: t(1.5)).isEmpty)
    #expect(timeline.isFinished)
    #expect(timeline.push(2, at: t(0.5)).isEmpty)
  }

  @Test func movesFirstFrameToStartWhenNothingIsShownAtStart() {
    let outputs = run([(0, 0.5), (1, 1)], range: range(0, 2))
    #expect(outputs == [output(0, 0), output(1, 1), output(1, 2)])
  }

  @Test func stillFrameBeforeStartFillsWholeRange() {
    let outputs = run([(0, 0), (1, 0.5)], range: range(1, 3))
    #expect(outputs == [output(1, 1), output(1, 3)])
  }

  @Test func noFrames() {
    #expect(run([], range: range(1, 3)).isEmpty)
  }

  @Test func resolveTreatsInvalidEndsAsWholeDuration() {
    #expect(
      TrimRange.resolve(start: .invalid, end: t(3), duration: t(5)) == range(0, 3))
    #expect(
      TrimRange.resolve(start: t(1), end: .invalid, duration: t(5)) == range(1, 5))
  }

  @Test func resolveClampsToDuration() {
    #expect(TrimRange.resolve(start: t(-1), end: t(6), duration: t(5)) == nil)
    #expect(TrimRange.resolve(start: t(1), end: t(6), duration: t(5)) == range(1, 5))
  }

  @Test func resolveReturnsNilForWholeOrEmptyRange() {
    #expect(TrimRange.resolve(start: .invalid, end: .invalid, duration: t(5)) == nil)
    #expect(TrimRange.resolve(start: .zero, end: t(5), duration: t(5)) == nil)
    #expect(TrimRange.resolve(start: t(2), end: t(2), duration: t(5)) == nil)
    #expect(TrimRange.resolve(start: t(3), end: t(2), duration: t(5)) == nil)
    #expect(TrimRange.resolve(start: t(1), end: t(2), duration: .invalid) == nil)
  }
}
