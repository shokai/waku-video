import CoreMedia

public enum TrimRange {
  /// AVPlayerViewのトリミングUIは、動かさなかった端の時刻を.invalidのままにする。元と同じ範囲か空の範囲ならnilを返す
  public static func resolve(start: CMTime, end: CMTime, duration: CMTime) -> CMTimeRange? {
    guard duration.isNumeric else { return nil }
    let lower = start.isNumeric ? max(start, .zero) : .zero
    let upper = end.isNumeric ? min(end, duration) : duration
    let isWholeDuration = lower == .zero && upper == duration
    guard lower < upper, !isWholeDuration else { return nil }
    return CMTimeRange(start: lower, end: upper)
  }
}

/// PTS順に渡したframeから、rangeを切り出すのに書くframeとその時刻を返す。時刻は元の動画のtimelineのまま扱う
public struct TrimTimeline<Frame> {
  public struct Output {
    public let frame: Frame
    public let time: CMTime
  }

  public let range: CMTimeRange
  public private(set) var isFinished = false
  /// startの時点で表示中のframe。可変フレームレートでは、PTSがstartよりずっと前にある事がある
  private var held: Frame?
  private var last: Output?

  public init(range: CMTimeRange) {
    self.range = range
  }

  public mutating func push(_ frame: Frame, at time: CMTime) -> [Output] {
    guard !isFinished else { return [] }
    guard time < range.end else {
      isFinished = true
      return []
    }
    guard time > range.start else {
      held = frame
      return []
    }
    var outputs: [Output] = []
    if last == nil {
      if let held {
        outputs.append(Output(frame: held, time: range.start))
        outputs.append(Output(frame: frame, time: time))
      } else {
        // 動画の先頭に空の区間を作らないよう、最初のframeをstartまで前に伸ばす
        outputs.append(Output(frame: frame, time: range.start))
      }
      held = nil
    } else {
      outputs.append(Output(frame: frame, time: time))
    }
    last = outputs.last
    return outputs
  }

  /// 最後のframeをendに複製して、endまでの静止時間も動画に残す
  public mutating func finish() -> [Output] {
    isFinished = true
    var outputs: [Output] = []
    if last == nil, let held {
      outputs.append(Output(frame: held, time: range.start))
      self.held = nil
    }
    if let tail = outputs.last ?? last, tail.time < range.end {
      outputs.append(Output(frame: tail.frame, time: range.end))
    }
    last = outputs.last ?? last
    return outputs
  }
}

extension TrimTimeline.Output: Equatable where Frame: Equatable {}
