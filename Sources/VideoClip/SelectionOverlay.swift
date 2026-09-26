import AppKit
import VideoClipCore

struct Selection: Sendable {
  var displayID: CGDirectDisplayID
  var screenFrame: CGRect
  var scale: CGFloat
  /// Cocoaのグローバル座標（左下原点）
  var globalRect: CGRect
}

@MainActor
final class SelectionOverlay {
  private var panels: [NSPanel] = []
  private var completion: ((Selection?) -> Void)?

  init(completion: @escaping (Selection?) -> Void) {
    self.completion = completion
  }

  func show() {
    let mouse = NSEvent.mouseLocation
    for screen in NSScreen.screens {
      guard let displayID = screen.displayID else { continue }
      let panel = OverlayPanel(frame: screen.frame)
      let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
      view.scale = screen.backingScaleFactor
      view.onSelect = { [weak self, weak panel] rect in
        guard let panel else { return }
        self?.finish(
          Selection(
            displayID: displayID,
            screenFrame: screen.frame,
            scale: screen.backingScaleFactor,
            globalRect: panel.convertToScreen(rect)
          ))
      }
      view.onCancel = { [weak self] in self?.finish(nil) }
      panel.contentView = view
      panel.orderFrontRegardless()
      panels.append(panel)
      if screen.frame.contains(mouse) {
        panel.makeKey()
        panel.makeFirstResponder(view)
      }
    }
  }

  private func finish(_ selection: Selection?) {
    guard let completion else { return }
    self.completion = nil
    for panel in panels { panel.orderOut(nil) }
    panels = []
    completion(selection)
  }
}

extension NSScreen {
  var displayID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }
}

/// nonactivatingにして、範囲選択中も前面appのfocusを奪わない（録画中にそのまま操作を続けられる）
private final class OverlayPanel: NSPanel {
  init(frame: CGRect) {
    super.init(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    setFrame(frame, display: false)
    level = .screenSaver
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    animationBehavior = .none
  }

  override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
  var scale: CGFloat = 1
  var onSelect: ((CGRect) -> Void)?
  var onCancel: (() -> Void)?

  private static let minimumSize: CGFloat = 16
  private var dragStart: CGPoint?
  private var selection: CGRect?

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    // appが非activeのままなのでcursor rectは効かない。activeAlwaysのtracking areaで毎回cursorを設定する
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
        owner: self))
  }

  override func cursorUpdate(with event: NSEvent) {
    NSCursor.crosshair.set()
  }

  override func mouseMoved(with event: NSEvent) {
    NSCursor.crosshair.set()
  }

  override func mouseDown(with event: NSEvent) {
    dragStart = convert(event.locationInWindow, from: nil)
    selection = nil
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard let dragStart else { return }
    // mouseDownを受けたviewにはcursorが画面外に出てもdragが届くので、ここで画面内に収める
    selection = RegionGeometry.normalizedClamped(
      from: dragStart, to: convert(event.locationInWindow, from: nil), in: bounds)
    NSCursor.crosshair.set()
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    defer {
      dragStart = nil
      needsDisplay = true
    }
    guard let selection, selection.width >= Self.minimumSize, selection.height >= Self.minimumSize
    else {
      self.selection = nil
      return
    }
    onSelect?(selection)
  }

  override func rightMouseDown(with event: NSEvent) {
    onCancel?()
  }

  override func keyDown(with event: NSEvent) {
    if Int(event.keyCode) == 53 {  // kVK_Escape
      onCancel?()
    } else {
      super.keyDown(with: event)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.black.withAlphaComponent(0.3).setFill()
    bounds.fill()
    guard let selection else { return }

    NSColor.clear.setFill()
    selection.fill(using: .copy)
    NSColor.white.setStroke()
    let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
    border.lineWidth = 1
    border.stroke()

    let label =
      "\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded()))"
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
      .foregroundColor: NSColor.white,
      .backgroundColor: NSColor.black.withAlphaComponent(0.6),
    ]
    let size = (label as NSString).size(withAttributes: attributes)
    var origin = CGPoint(x: selection.minX, y: selection.minY - size.height - 4)
    if origin.y < bounds.minY { origin.y = selection.minY + 4 }
    (label as NSString).draw(at: origin, withAttributes: attributes)
  }
}
