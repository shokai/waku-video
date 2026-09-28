import CoreGraphics
import Testing

@testable import WakuVideoCore

struct OutputSizingTests {
  @Test func keepsSizeWithinLimits() {
    #expect(
      OutputSizing.outputSize(pointSize: CGSize(width: 800, height: 600), scale: 2)
        == PixelSize(width: 1600, height: 1200))
  }

  @Test(arguments: [
    CGSize(width: 2560, height: 1440),  // 5K Retina
    CGSize(width: 3008, height: 1692),  // 6K Retina
    CGSize(width: 2500, height: 2500),
    CGSize(width: 1540, height: 1532),
    CGSize(width: 1117, height: 2560),
  ])
  func clampsLargeRegions(pointSize: CGSize) {
    let size = OutputSizing.outputSize(pointSize: pointSize, scale: 2)
    #expect(size.width % 2 == 0)
    #expect(size.height % 2 == 0)
    #expect(max(size.width, size.height) <= OutputSizing.maxLongEdge)
    #expect(OutputSizing.macroblocks(size) <= OutputSizing.maxMacroblocks)
    let sourceAspect = pointSize.width / pointSize.height
    let outputAspect = CGFloat(size.width) / CGFloat(size.height)
    #expect(abs(outputAspect / sourceAspect - 1) < 0.01)
  }

  @Test func fiveKFullScreenBecomes4096x2304() {
    #expect(
      OutputSizing.outputSize(pointSize: CGSize(width: 2560, height: 1440), scale: 2)
        == PixelSize(width: 4096, height: 2304))
  }
}
