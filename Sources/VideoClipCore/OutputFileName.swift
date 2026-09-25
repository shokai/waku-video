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
}
