import CoreGraphics
import Testing

@testable import VideoClipCore

struct ControlPlacementTests {
  let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
  let size = CGSize(width: 80, height: 28)

  @Test func placesBelowRightAligned() {
    let region = CGRect(x: 200, y: 300, width: 400, height: 300)
    let frame = ControlPlacement.frame(size: size, outside: region, in: screen, gap: 8)
    #expect(frame == CGRect(x: 520, y: 264, width: 80, height: 28))
  }

  @Test func placesAboveWhenNoRoomBelow() {
    let region = CGRect(x: 200, y: 0, width: 400, height: 300)
    let frame = ControlPlacement.frame(size: size, outside: region, in: screen, gap: 8)
    #expect(frame == CGRect(x: 520, y: 308, width: 80, height: 28))
  }

  @Test func placesRightWhenRegionIsFullHeight() {
    let region = CGRect(x: 200, y: 0, width: 400, height: 982)
    let frame = ControlPlacement.frame(size: size, outside: region, in: screen, gap: 8)
    #expect(frame == CGRect(x: 608, y: 0, width: 80, height: 28))
  }

  @Test func placesLeftWhenNoRoomRight() {
    let region = CGRect(x: 800, y: 0, width: 712, height: 982)
    let frame = ControlPlacement.frame(size: size, outside: region, in: screen, gap: 8)
    #expect(frame == CGRect(x: 712, y: 0, width: 80, height: 28))
  }

  @Test func returnsNilWhenRegionCoversScreen() {
    #expect(ControlPlacement.frame(size: size, outside: screen, in: screen, gap: 8) == nil)
  }

  @Test func clampsIntoScreenOnSecondaryDisplay() {
    let secondary = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
    let region = CGRect(x: -1920, y: 600, width: 40, height: 100)
    let frame = ControlPlacement.frame(size: size, outside: region, in: secondary, gap: 8)
    #expect(frame == CGRect(x: -1920, y: 564, width: 80, height: 28))
  }

  @Test(arguments: [
    CGRect(x: 0, y: 0, width: 1512, height: 900),
    CGRect(x: 0, y: 50, width: 1512, height: 932),
    CGRect(x: 10, y: 10, width: 1450, height: 962),
    CGRect(x: 700, y: 400, width: 100, height: 100),
  ])
  func neverOverlapsRegion(region: CGRect) {
    guard let frame = ControlPlacement.frame(size: size, outside: region, in: screen, gap: 8)
    else { return }
    #expect(!frame.intersects(region))
    #expect(screen.contains(frame))
  }
}
