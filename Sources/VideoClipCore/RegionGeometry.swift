import CoreGraphics

public enum RegionGeometry {
  /// Cocoaのグローバル座標（左下原点）の矩形を、SCStreamConfiguration.sourceRectが要求するディスプレイローカルの左上原点の座標に変換する
  public static func sourceRect(globalRect: CGRect, screenFrame: CGRect) -> CGRect {
    CGRect(
      x: globalRect.minX - screenFrame.minX,
      y: screenFrame.maxY - globalRect.maxY,
      width: globalRect.width,
      height: globalRect.height
    )
  }

  public static func globalRect(sourceRect: CGRect, screenFrame: CGRect) -> CGRect {
    CGRect(
      x: screenFrame.minX + sourceRect.minX,
      y: screenFrame.maxY - sourceRect.maxY,
      width: sourceRect.width,
      height: sourceRect.height
    )
  }

  public static func normalizedClamped(from start: CGPoint, to end: CGPoint, in bounds: CGRect)
    -> CGRect
  {
    let clamp = { (point: CGPoint) in
      CGPoint(
        x: min(max(point.x, bounds.minX), bounds.maxX),
        y: min(max(point.y, bounds.minY), bounds.maxY)
      )
    }
    let a = clamp(start)
    let b = clamp(end)
    return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
  }

  /// 端点をpixel格子に丸め、pixel単位の幅と高さを偶数にする。H.264の4:2:0は奇数の幅・高さを扱えない
  public static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
    let minX = (rect.minX * scale).rounded()
    let minY = (rect.minY * scale).rounded()
    let width = evenFloor((rect.maxX * scale).rounded() - minX)
    let height = evenFloor((rect.maxY * scale).rounded() - minY)
    return CGRect(x: minX / scale, y: minY / scale, width: width / scale, height: height / scale)
  }

  private static func evenFloor(_ value: CGFloat) -> CGFloat {
    let floored = max(0, value.rounded(.down))
    return floored - floored.truncatingRemainder(dividingBy: 2)
  }
}
