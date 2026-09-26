import AppKit
import VideoClipCore

/// 録画範囲の枠と停止ボタン。どちらも範囲の外側に置くので、動画には映らない
@MainActor
final class RecordingIndicator {
  private static let lineWidth: CGFloat = 2
  private static let buttonSize = CGSize(width: 76, height: 28)
  private static let buttonGap: CGFloat = 6

  private let borderPanel: NSPanel
  private let stopPanel: NSPanel?

  init(globalRect: CGRect, screenFrame: CGRect, onStop: @escaping () -> Void) {
    let outline = globalRect.insetBy(dx: -Self.lineWidth, dy: -Self.lineWidth)
    let borderFrame = outline.intersection(screenFrame)
    borderPanel = Self.makePanel(frame: borderFrame)
    borderPanel.ignoresMouseEvents = true
    // window serverがwindowの位置を丸めても線が範囲に入らないよう、要求した位置ではなく実際のframeから描く位置を決める
    let actualFrame = borderPanel.frame
    borderPanel.contentView = BorderView(
      frame: CGRect(origin: .zero, size: actualFrame.size),
      region: globalRect.offsetBy(dx: -actualFrame.minX, dy: -actualFrame.minY),
      lineWidth: Self.lineWidth)

    // 範囲の外に置く余白が無ければ停止ボタンは出さない。メニューバーのアイコンか、macOSの「共有を停止」で止める
    if let buttonFrame = ControlPlacement.frame(
      size: Self.buttonSize, outside: outline, in: screenFrame, gap: Self.buttonGap)
    {
      let panel = Self.makePanel(frame: buttonFrame)
      panel.contentView = StopButtonView(
        frame: CGRect(origin: .zero, size: buttonFrame.size), onStop: onStop)
      stopPanel = panel
    } else {
      stopPanel = nil
    }
  }

  func show() {
    borderPanel.orderFrontRegardless()
    stopPanel?.orderFrontRegardless()
  }

  func close() {
    borderPanel.orderOut(nil)
    stopPanel?.orderOut(nil)
  }

  private static func makePanel(frame: CGRect) -> NSPanel {
    let panel = NSPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.setFrame(frame, display: false)
    panel.level = .screenSaver
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    return panel
  }
}

private final class BorderView: NSView {
  private let region: CGRect
  private let lineWidth: CGFloat

  init(frame: CGRect, region: CGRect, lineWidth: CGFloat) {
    self.region = region
    self.lineWidth = lineWidth
    super.init(frame: frame)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.systemRed.setStroke()
    let path = NSBezierPath(rect: region.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2))
    path.lineWidth = lineWidth
    path.stroke()
  }
}

private final class StopButtonView: NSView {
  private let onStop: () -> Void
  private var isPressed = false {
    didSet { needsDisplay = true }
  }

  init(frame: CGRect, onStop: @escaping () -> Void) {
    self.onStop = onStop
    super.init(frame: frame)
    setAccessibilityRole(.button)
    setAccessibilityLabel("録画を停止")
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // appを非activeのままにしているので、最初のclickで押せるようにする
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    isPressed = true
  }

  override func mouseDragged(with event: NSEvent) {
    isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
  }

  override func mouseUp(with event: NSEvent) {
    let shouldStop = isPressed
    isPressed = false
    if shouldStop { onStop() }
  }

  override func accessibilityPerformPress() -> Bool {
    onStop()
    return true
  }

  override func draw(_ dirtyRect: NSRect) {
    let background = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
    NSColor.black.withAlphaComponent(isPressed ? 0.9 : 0.75).setFill()
    background.fill()

    let square = CGRect(x: 10, y: (bounds.height - 10) / 2, width: 10, height: 10)
    NSColor.systemRed.setFill()
    NSBezierPath(roundedRect: square, xRadius: 2, yRadius: 2).fill()

    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13, weight: .medium),
      .foregroundColor: NSColor.white,
    ]
    let label = "停止" as NSString
    let labelSize = label.size(withAttributes: attributes)
    label.draw(
      at: CGPoint(x: square.maxX + 8, y: (bounds.height - labelSize.height) / 2),
      withAttributes: attributes)
  }
}
