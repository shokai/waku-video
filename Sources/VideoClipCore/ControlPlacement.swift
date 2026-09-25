import CoreGraphics

public enum ControlPlacement {
  /// 録画範囲に重ならない位置を、範囲の下・上・右・左の順に探す。画面内に置けなければnil。
  /// 座標はCocoaのグローバル座標（左下原点）
  public static func frame(size: CGSize, outside region: CGRect, in screen: CGRect, gap: CGFloat)
    -> CGRect?
  {
    let alignedRight = clamp(region.maxX - size.width, screen.minX, screen.maxX - size.width)
    let alignedBottom = clamp(region.minY, screen.minY, screen.maxY - size.height)
    let candidates = [
      CGPoint(x: alignedRight, y: region.minY - gap - size.height),
      CGPoint(x: alignedRight, y: region.maxY + gap),
      CGPoint(x: region.maxX + gap, y: alignedBottom),
      CGPoint(x: region.minX - gap - size.width, y: alignedBottom),
    ]
    return candidates.lazy
      .map { CGRect(origin: $0, size: size) }
      .first { screen.contains($0) && !$0.intersects(region) }
  }

  private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(max(value, lower), upper)
  }
}
