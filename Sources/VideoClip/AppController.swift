import AppKit
import OSLog
import VideoClipCore

private let logger = Logger(subsystem: "org.shokai.VideoClip", category: "AppController")

@MainActor
private final class RecordingSession {
  let id: UUID
  let tempURL: URL
  let startedAt: Date
  let indicator: RecordingIndicator
  var recorder: ScreenRecorder?
  var isStopping = false

  init(id: UUID, tempURL: URL, startedAt: Date, indicator: RecordingIndicator) {
    self.id = id
    self.tempURL = tempURL
    self.startedAt = startedAt
    self.indicator = indicator
  }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
  private enum State {
    case idle
    case preparing
    case selecting(SelectionOverlay)
    case recording(RecordingSession)
  }

  private var state: State = .idle {
    didSet { updateStatusItem() }
  }
  private var statusItem: NSStatusItem?
  private let menu = NSMenu()
  /// 起動引数`-SmokeRecordSeconds 3`で、主画面中央を指定秒数だけ録画して終了する。録画処理を手で操作せずに確かめられるようにするため
  private var isSmokeTest = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    setUpStatusItem()

    let smokeSeconds = UserDefaults.standard.double(forKey: "SmokeRecordSeconds")
    if smokeSeconds > 0 {
      isSmokeTest = true
      runSmokeTest(seconds: smokeSeconds)
    }
  }

  // MARK: - Status item

  private func setUpStatusItem() {
    let startItem = NSMenuItem(
      title: "範囲を選択して録画", action: #selector(startClicked), keyEquivalent: "")
    startItem.target = self
    menu.addItem(startItem)
    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(
        title: "VideoClipを終了", action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"))

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    updateStatusItem()
  }

  private func updateStatusItem() {
    guard let statusItem, let button = statusItem.button else { return }
    if case .recording(let session) = state, !session.isStopping {
      button.image = NSImage(
        systemSymbolName: "stop.circle.fill", accessibilityDescription: "録画を停止")
      // menuを外すと、クリックでbuttonのactionが呼ばれる
      statusItem.menu = nil
      button.target = self
      button.action = #selector(stopClicked)
    } else {
      button.image = NSImage(
        systemSymbolName: "record.circle", accessibilityDescription: "VideoClip")
      statusItem.menu = menu
    }
  }

  @objc private func startClicked() {
    if case .idle = state { beginSelection() }
  }

  @objc private func stopClicked() {
    stopRecording()
  }

  // MARK: - Selection

  private func beginSelection() {
    state = .preparing
    guard Permissions.ensureScreenCapture() else {
      state = .idle
      return
    }
    Task {
      do {
        try await ScreenRecorder.preflight()
      } catch {
        state = .idle
        showError("画面の情報を取得できませんでした", error)
        return
      }
      guard case .preparing = state else { return }
      let overlay = SelectionOverlay { [weak self] selection in
        self?.selectionFinished(selection)
      }
      state = .selecting(overlay)
      overlay.show()
    }
  }

  private func selectionFinished(_ selection: Selection?) {
    guard case .selecting = state else { return }
    guard let selection else {
      state = .idle
      return
    }
    startRecording(selection)
  }

  // MARK: - Recording

  private func startRecording(_ selection: Selection) {
    let sourceRect = RegionGeometry.pixelAligned(
      RegionGeometry.sourceRect(
        globalRect: selection.globalRect, screenFrame: selection.screenFrame),
      scale: selection.scale)
    let outputSize = OutputSizing.outputSize(pointSize: sourceRect.size, scale: selection.scale)

    // indicatorとrecorderがcallbackを保持するので、sessionを直接captureすると循環参照になる。idで引く
    let sessionID = UUID()
    let indicator = RecordingIndicator(
      globalRect: RegionGeometry.globalRect(
        sourceRect: sourceRect, screenFrame: selection.screenFrame),
      screenFrame: selection.screenFrame,
      onStop: { [weak self] in self?.stopRecording(sessionID: sessionID) })
    indicator.show()

    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("VideoClip-\(UUID().uuidString)")
      .appendingPathExtension("mp4")
    let session = RecordingSession(
      id: sessionID, tempURL: tempURL, startedAt: Date(), indicator: indicator)
    state = .recording(session)

    let request = RecordingRequest(
      displayID: selection.displayID, sourceRect: sourceRect, outputSize: outputSize,
      outputURL: tempURL)
    Task {
      do {
        session.recorder = try await ScreenRecorder.start(request) { [weak self] _ in
          Task { @MainActor in self?.stopRecording(sessionID: sessionID) }
        }
      } catch {
        guard currentSession(id: sessionID) != nil else { return }
        state = .idle
        indicator.close()
        showError("録画を開始できませんでした", error)
      }
    }
  }

  private func currentSession(id: UUID) -> RecordingSession? {
    guard case .recording(let session) = state, session.id == id else { return nil }
    return session
  }

  private func stopRecording() {
    guard case .recording(let session) = state else { return }
    stopRecording(sessionID: session.id)
  }

  /// ユーザーの停止操作と、システム側でstreamが止まった時の両方から呼ばれる
  private func stopRecording(sessionID: UUID) {
    guard let session = currentSession(id: sessionID), !session.isStopping,
      let recorder = session.recorder
    else { return }
    session.isStopping = true
    session.indicator.close()
    updateStatusItem()
    Task {
      do {
        try await recorder.stop()
        finalize(session)
      } catch {
        finalize(session, error: error)
      }
    }
  }

  private func finalize(_ session: RecordingSession, error: (any Error)? = nil) {
    guard currentSession(id: session.id) != nil else { return }
    state = .idle
    defer {
      if isSmokeTest { NSApp.terminate(nil) }
    }

    let fileManager = FileManager.default
    if let error {
      try? fileManager.removeItem(at: session.tempURL)
      showError("録画を保存できませんでした", error)
      return
    }

    // `-SaveDirectory <path>`（起動引数かdefaults）で保存先を変えられる。make smokeがデスクトップを汚さないために使う
    let directory =
      UserDefaults.standard.url(forKey: "SaveDirectory")
      ?? fileManager.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    let destination = OutputFileName.uniqueURL(
      in: directory, baseName: OutputFileName.baseName(for: session.startedAt)
    ) { fileManager.fileExists(atPath: $0.path) }
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      try fileManager.moveItem(at: session.tempURL, to: destination)
      logger.info("saved \(destination.path, privacy: .public)")
      if !isSmokeTest { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
    } catch {
      NSWorkspace.shared.activateFileViewerSelecting([session.tempURL])
      showError("\(directory.lastPathComponent)に保存できませんでした", error)
    }
  }

  private func showError(_ message: String, _ error: (any Error)?) {
    logger.error("\(message): \(error?.localizedDescription ?? "", privacy: .public)")
    if isSmokeTest { return }
    NSApp.activate()
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = message
    alert.informativeText = error?.localizedDescription ?? ""
    alert.runModal()
  }

  // MARK: - Smoke test

  private func runSmokeTest(seconds: Double) {
    guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.screens.first,
      let displayID = screen.displayID
    else {
      logger.error("smoke test: screen capture is not permitted")
      NSApp.terminate(nil)
      return
    }
    let size = CGSize(width: 800, height: 600)
    let rect = CGRect(
      x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
      width: size.width, height: size.height)
    startRecording(
      Selection(
        displayID: displayID, screenFrame: screen.frame, scale: screen.backingScaleFactor,
        globalRect: rect))
    Task {
      try? await Task.sleep(for: .seconds(seconds))
      stopRecording()
    }
  }
}
