import AVKit
import AppKit
import OSLog
import WakuVideoCore

private let logger = Logger(subsystem: "org.shokai.WakuVideo", category: "TrimWindow")

/// AVPlayerView標準のトリミングUI（QuickTime Playerの⌘Tと同じ）で範囲を選ばせる
@MainActor
final class TrimWindow: NSObject, NSWindowDelegate {
  enum Outcome {
    case cancelled
    case trimmed(CMTimeRange)
    case failed((any Error)?)
  }

  private static let minContentSize = CGSize(width: 480, height: 270)
  private static let maxScreenFraction: CGFloat = 0.7

  private let window: NSWindow
  private let playerView = AVPlayerView()
  private var onFinish: ((Outcome) -> Void)?
  private var statusObservation: NSKeyValueObservation?
  private var hasBegunTrimming = false

  init(url: URL, videoSize: CGSize, onFinish: @escaping (Outcome) -> Void) {
    self.onFinish = onFinish
    playerView.player = AVPlayer(url: url)
    playerView.updatesNowPlayingInfoCenter = false
    window = NSWindow(
      contentRect: CGRect(origin: .zero, size: Self.contentSize(for: videoSize)),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.title = url.lastPathComponent
    window.contentMinSize = Self.minContentSize
    window.contentView = playerView
    super.init()
    window.delegate = self
  }

  func show() {
    window.center()
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    // canBeginTrimmingはplayer itemが再生できる状態になるまでfalseのまま
    statusObservation = playerView.player?.currentItem?.observe(
      \.status, options: [.initial, .new]
    ) { [weak self] _, _ in
      Task { @MainActor in self?.beginTrimmingIfReady() }
    }
  }

  private func beginTrimmingIfReady() {
    guard onFinish != nil, !hasBegunTrimming, let item = playerView.player?.currentItem else {
      return
    }
    switch item.status {
    case .readyToPlay:
      hasBegunTrimming = true
      statusObservation = nil
      guard playerView.canBeginTrimming else {
        logger.error("canBeginTrimming is false although the item is ready to play")
        finish(.failed(nil))
        return
      }
      playerView.beginTrimming { [weak self] result in
        Task { @MainActor in self?.trimmingEnded(result) }
      }
    case .failed:
      finish(.failed(item.error))
    default:
      break
    }
  }

  private func trimmingEnded(_ result: AVPlayerViewTrimResult) {
    logger.info("trimming ended: \(result == .okButton ? "ok" : "cancel", privacy: .public)")
    guard result == .okButton, let item = playerView.player?.currentItem,
      let range = TrimRange.resolve(
        start: item.reversePlaybackEndTime, end: item.forwardPlaybackEndTime,
        duration: item.duration)
    else {
      finish(.cancelled)
      return
    }
    finish(.trimmed(range))
  }

  // トリミング中に窓を閉じても、beginTrimmingのhandlerは呼ばれない
  func windowWillClose(_ notification: Notification) {
    finish(.cancelled)
  }

  /// トリミングUIのhandlerと窓を閉じた時のどちらからも呼ばれるので、最初の1回だけ処理する
  private func finish(_ outcome: Outcome) {
    guard let onFinish else { return }
    self.onFinish = nil
    statusObservation = nil
    playerView.player?.pause()
    playerView.player = nil
    window.delegate = nil
    window.close()
    onFinish(outcome)
  }

  /// Retinaの録画を物理pixelの等倍で見せ、画面の7割に収まらなければ縮める
  private static func contentSize(for videoSize: CGSize) -> CGSize {
    guard let screen = NSScreen.main, videoSize.width > 0, videoSize.height > 0 else {
      return minContentSize
    }
    let visible = screen.visibleFrame.size
    let factor = min(
      1 / screen.backingScaleFactor,
      visible.width * maxScreenFraction / videoSize.width,
      visible.height * maxScreenFraction / videoSize.height)
    return CGSize(
      width: max(minContentSize.width, (videoSize.width * factor).rounded()),
      height: max(minContentSize.height, (videoSize.height * factor).rounded()))
  }
}
