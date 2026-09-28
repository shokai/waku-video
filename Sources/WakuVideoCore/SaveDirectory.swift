import Foundation

public enum SaveDirectory {
  /// UserDefaults.url(forKey:)はpathをstatし、応答しないNASが保存先だとメニューを開く度に固まるので使わない。pathの解釈はurl(forKey:)に揃えている
  public static func url(fromPath path: String?, fallback: @autoclosure () -> URL) -> URL {
    guard let path, !path.isEmpty else { return fallback() }
    return URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
  }
}
