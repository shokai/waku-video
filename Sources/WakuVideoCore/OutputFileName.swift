import Foundation

public enum OutputFileName {
  /// "2026-09-25 18.30.00"の形式。DateFormatterはユーザーの暦・12時間表示の設定に影響されるので使わない
  public static func baseName(for date: Date, timeZone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return String(
      format: "%04d-%02d-%02d %02d.%02d.%02d",
      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
    )
  }

  public static func uniqueURL(
    in directory: URL,
    baseName: String,
    pathExtension: String = "mp4",
    exists: (URL) -> Bool
  ) -> URL {
    var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(pathExtension)
    var index = 2
    while exists(candidate) {
      candidate = directory.appendingPathComponent("\(baseName) (\(index))")
        .appendingPathExtension(pathExtension)
      index += 1
    }
    return candidate
  }

  /// "foo.mp4"は"foo_2.mp4"、"foo_2.mp4"は"foo_3.mp4"のように、末尾の`_数字`を版番号として繰り上げる。既にあれば更に繰り上げる
  public static func trimmedURL(
    for source: URL,
    pathExtension: String = "mp4",
    exists: (URL) -> Bool
  ) -> URL {
    let directory = source.deletingLastPathComponent()
    var baseName = source.deletingPathExtension().lastPathComponent
    var index = 2
    if let separator = baseName.lastIndex(of: "_") {
      let digits = baseName[baseName.index(after: separator)...]
      if !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }),
        let number = Int(digits), number < Int.max
      {
        baseName = String(baseName[..<separator])
        index = number + 1
      }
    }
    var candidate = directory.appendingPathComponent("\(baseName)_\(index)")
      .appendingPathExtension(pathExtension)
    // Int.maxまで埋まっていたら既にある名前を返す。上書きはせず、移す時にmoveItemが失敗する
    while index < Int.max, exists(candidate) {
      index += 1
      candidate = directory.appendingPathComponent("\(baseName)_\(index)")
        .appendingPathExtension(pathExtension)
    }
    return candidate
  }
}
