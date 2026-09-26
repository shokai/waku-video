import CoreGraphics
import Testing

@testable import VideoClipCore

struct RegionGeometryTests {
  @Test func sourceRectOnMainScreen() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let global = CGRect(x: 100, y: 700, width: 300, height: 200)
    #expect(
      RegionGeometry.sourceRect(globalRect: global, screenFrame: screen)
        == CGRect(x: 100, y: 82, width: 300, height: 200))
  }

  @Test func sourceRectOnSecondaryScreenWithNegativeOrigin() {
    let screen = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
    let global = CGRect(x: -1900, y: -1080, width: 400, height: 300)
    #expect(
      RegionGeometry.sourceRect(globalRect: global, screenFrame: screen)
        == CGRect(x: 20, y: 780, width: 400, height: 300))
  }

  @Test func sourceRectTouchingTopEdge() {
    let screen = CGRect(x: 1512, y: 200, width: 2560, height: 1440)
    let global = CGRect(x: 1512, y: 1440, width: 2560, height: 200)
    #expect(
      RegionGeometry.sourceRect(globalRect: global, screenFrame: screen)
        == CGRect(x: 0, y: 0, width: 2560, height: 200))
  }

  @Test func globalRectIsInverseOfSourceRect() {
    let screen = CGRect(x: -1920, y: 300, width: 1920, height: 1080)
    let global = CGRect(x: -1500, y: 700, width: 640, height: 360)
    let local = RegionGeometry.sourceRect(globalRect: global, screenFrame: screen)
    #expect(RegionGeometry.globalRect(sourceRect: local, screenFrame: screen) == global)
  }

  @Test func normalizedClampedHandlesReverseDragAndOutOfBounds() {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    let rect = RegionGeometry.normalizedClamped(
      from: CGPoint(x: 500, y: 100), to: CGPoint(x: -50, y: 900), in: bounds)
    #expect(rect == CGRect(x: 0, y: 100, width: 500, height: 500))
  }

  @Test func pixelAlignedRoundsToEvenPixels() {
    let rect = RegionGeometry.pixelAligned(
      CGRect(x: 10.25, y: 20.5, width: 100.5, height: 50.75), scale: 2)
    #expect(rect == CGRect(x: 10.5, y: 20.5, width: 100, height: 51))
    #expect(Int(rect.width * 2) % 2 == 0)
    #expect(Int(rect.height * 2) % 2 == 0)
  }

  @Test func pixelAlignedAtScaleOne() {
    let rect = RegionGeometry.pixelAligned(CGRect(x: 0, y: 0, width: 101, height: 77), scale: 1)
    #expect(rect == CGRect(x: 0, y: 0, width: 100, height: 76))
  }

  @Test func pixelAlignedStaysInsideScreen() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let rect = RegionGeometry.pixelAligned(screen, scale: 2)
    #expect(screen.contains(rect))
  }
}
