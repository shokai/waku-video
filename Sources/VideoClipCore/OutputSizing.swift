import CoreGraphics

public struct PixelSize: Equatable, Sendable {
  public var width: Int
  public var height: Int

  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }
}

public enum OutputSizing {
  // VideoToolboxのH.264エンコーダは、どちらかの辺が4096pxを超えると何も書き出さない
  public static let maxLongEdge = 4096
  // H.264 Level 5.2のMaxFS（4096×2304相当）。これを超えるとLevel 6になり、再生できない環境がある
  public static let maxMacroblocks = 36_864

  public static func outputSize(pointSize: CGSize, scale: CGFloat) -> PixelSize {
    let width = Double((pointSize.width * scale).rounded())
    let height = Double((pointSize.height * scale).rounded())
    guard width > 0, height > 0 else { return PixelSize(width: 0, height: 0) }

    var factor = min(
      1,
      Double(maxLongEdge) / max(width, height),
      (Double(maxMacroblocks * 16 * 16) / (width * height)).squareRoot()
    )
    while true {
      let size = PixelSize(width: evenFloor(width * factor), height: evenFloor(height * factor))
      // 面積で求めたfactorでも、16pxへの切り上げでmacroblock数が上限を超える事がある
      if macroblocks(size) <= maxMacroblocks { return size }
      factor *= 0.995
    }
  }

  static func macroblocks(_ size: PixelSize) -> Int {
    ((size.width + 15) / 16) * ((size.height + 15) / 16)
  }

  private static func evenFloor(_ value: Double) -> Int {
    // 5120×0.8が4095.999…になる等の浮動小数点誤差で、偶数化の後に2px欠けないよう、切り捨て前に僅かに足す
    let floored = Int((value + 1e-6).rounded(.down))
    return max(2, floored - floored % 2)
  }
}
