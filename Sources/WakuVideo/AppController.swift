import AppKit
import CoreMedia
import OSLog
import UniformTypeIdentifiers
import WakuVideoCore

private let logger = Logger(subsystem: "org.shokai.WakuVideo", category: "AppController")

@MainActor
private final class RecordingSession {
  let id: UUID
  let tempURL: URL
  /// 録画中にdefaultsを書き換えられても、録画を始めた時点の保存先に保存する
  let saveDirectory: URL
  let startedAt: Date
  let indicator: RecordingIndicator
  var recorder: ScreenRecorder?
  /// 録画の開始処理を待っている間にも停止を受け付けるので、recorderの有無とは別に持つ
  var isStopRequested = false

  init(
    id: UUID, tempURL: URL, saveDirectory: URL, startedAt: Date, indicator: RecordingIndicator
  ) {
    self.id = id
    self.tempURL = tempURL
    self.saveDirectory = saveDirectory
    self.startedAt = startedAt
    self.indicator = indicator
  }
}

private struct DescribedError: LocalizedError {
  let errorDescription: String?
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
  private static let saveDirectoryKey = "SaveDirectory"

  private enum State {
    case idle
    case preparing
    case selecting(SelectionOverlay)
    case recording(RecordingSession)
    case choosingSaveDirectory
    /// トリミングするファイルを選び、トリミングできる動画か調べている間
    case preparingTrim
    case trimming(TrimWindow)
    case savingTrim
  }

  private var state: State = .idle {
    didSet { updateStatusItem() }
  }
  private var statusItem: NSStatusItem?
  private let menu = NSMenu()
  private let saveDirectoryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  /// 起動引数`-SmokeRecordSeconds 3`で、主画面中央を指定秒数だけ録画して終了する。録画処理を手で操作せずに確かめられるようにするため
  private var smokeRecordSeconds: Double?
  private var isTerminating = false
  private var lastSavedURL: URL?

  func applicationDidFinishLaunching(_ notification: Notification) {
    setUpStatusItem()

    let smokeSeconds = UserDefaults.standard.double(forKey: "SmokeRecordSeconds")
    if smokeSeconds > 0 {
      smokeRecordSeconds = smokeSeconds
      runSmokeTest()
    }
  }

  /// 録画中や書き出し中に終了すると録画やトリミングの結果を失うので、保存し終わるまで終了を待たせる
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    switch state {
    case .recording(let session):
      isTerminating = true
      stopRecording(sessionID: session.id)
      return .terminateLater
    case .savingTrim:
      isTerminating = true
      return .terminateLater
    default:
      return .terminateNow
    }
  }

  // MARK: - Status item

  private func setUpStatusItem() {
    let startItem = NSMenuItem(
      title: "範囲を選択して録画", action: #selector(startClicked), keyEquivalent: "")
    startItem.target = self
    menu.addItem(startItem)
    let trimItem = NSMenuItem(
      title: "動画をトリミング…", action: #selector(trimClicked), keyEquivalent: "")
    trimItem.target = self
    menu.addItem(trimItem)
    menu.addItem(.separator())
    menu.addItem(saveDirectoryItem)
    let chooseSaveDirectoryItem = NSMenuItem(
      title: "保存先を変更…", action: #selector(chooseSaveDirectoryClicked), keyEquivalent: "")
    chooseSaveDirectoryItem.target = self
    menu.addItem(chooseSaveDirectoryItem)
    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(
        title: "WakuVideoを終了", action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"))
    menu.delegate = self

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    updateStatusItem()
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    let directory = saveDirectory
    // displayName(atPath:)はファイルシステムに触るので使わない
    saveDirectoryItem.title = "保存先: \(directory.lastPathComponent)"
    saveDirectoryItem.toolTip = (directory.path as NSString).abbreviatingWithTildeInPath
  }

  private func updateStatusItem() {
    guard let statusItem, let button = statusItem.button else { return }
    if case .recording(let session) = state, !session.isStopRequested {
      button.image = NSImage(
        systemSymbolName: "stop.circle.fill", accessibilityDescription: "録画を停止")
      // menuを外すと、クリックでbuttonのactionが呼ばれる
      statusItem.menu = nil
      button.target = self
      button.action = #selector(stopClicked)
    } else {
      button.image = NSImage(
        systemSymbolName: "record.circle", accessibilityDescription: "WakuVideo")
      statusItem.menu = menu
    }
  }

  @objc private func startClicked() {
    if case .idle = state { beginSelection() }
  }

  // 停止後もmp4を保存し終えるまではrecording状態が続くので、その間は開始・トリミング・保存先の変更を押せないようにする
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard
      menuItem.action == #selector(startClicked)
        || menuItem.action == #selector(trimClicked)
        || menuItem.action == #selector(chooseSaveDirectoryClicked)
    else { return true }
    if case .idle = state { return true }
    return false
  }

  @objc private func stopClicked() {
    stopRecording()
  }

  // MARK: - Save directory

  /// 起動引数`-SaveDirectory <path>`はメニューで選んだ値より優先される。make smokeがユーザーの保存先を汚さないために使う
  private var saveDirectory: URL {
    SaveDirectory.url(
      fromPath: UserDefaults.standard.string(forKey: Self.saveDirectoryKey),
      fallback: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0])
  }

  @objc private func chooseSaveDirectoryClicked() {
    guard case .idle = state else { return }
    let panel = NSOpenPanel()
    panel.message = "録画したmp4の保存先を選んでください"
    panel.prompt = "選択"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.directoryURL = saveDirectory
    state = .choosingSaveDirectory
    NSApp.activate()
    let response = panel.runModal()
    state = .idle
    guard response == .OK, let url = panel.url else { return }
    UserDefaults.standard.set(url.path, forKey: Self.saveDirectoryKey)
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
      .appendingPathComponent("WakuVideo-\(UUID().uuidString)")
      .appendingPathExtension("mp4")
    let session = RecordingSession(
      id: sessionID, tempURL: tempURL, saveDirectory: saveDirectory, startedAt: Date(),
      indicator: indicator)
    state = .recording(session)

    let request = RecordingRequest(
      displayID: selection.displayID, sourceRect: sourceRect, outputSize: outputSize,
      outputURL: tempURL)
    Task {
      do {
        let recorder = try await ScreenRecorder.start(request) { [weak self] _ in
          Task { @MainActor in self?.stopRecording(sessionID: sessionID) }
        }
        session.recorder = recorder
        if session.isStopRequested {
          finishRecording(session, recorder: recorder)
        } else if let seconds = smokeRecordSeconds {
          try? await Task.sleep(for: .seconds(seconds))
          stopRecording(sessionID: sessionID)
        }
      } catch {
        guard currentSession(id: sessionID) != nil else { return }
        indicator.close()
        try? FileManager.default.removeItem(at: tempURL)
        endSession(errorMessage: "録画を開始できませんでした", error: error)
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

  private func stopRecording(sessionID: UUID) {
    guard let session = currentSession(id: sessionID), !session.isStopRequested else { return }
    session.isStopRequested = true
    session.indicator.close()
    updateStatusItem()
    // recorderがまだ無ければ、開始処理が終わった所でfinishRecordingする
    if let recorder = session.recorder {
      finishRecording(session, recorder: recorder)
    }
  }

  private func finishRecording(_ session: RecordingSession, recorder: ScreenRecorder) {
    Task {
      do {
        try await recorder.stop()
        await save(session)
      } catch {
        try? FileManager.default.removeItem(at: session.tempURL)
        endSession(errorMessage: "録画を保存できませんでした", error: error)
      }
    }
  }

  private func save(_ session: RecordingSession) async {
    let directory = session.saveDirectory
    do {
      let destination = try await Self.moveRecording(
        session.tempURL, into: directory,
        baseName: OutputFileName.baseName(for: session.startedAt))
      logger.info("saved \(destination.path, privacy: .public)")
      lastSavedURL = destination
      if smokeRecordSeconds == nil {
        NSWorkspace.shared.activateFileViewerSelecting([destination])
      }
      endSession()
    } catch {
      NSWorkspace.shared.activateFileViewerSelecting([session.tempURL])
      endSession(errorMessage: "\(directory.lastPathComponent)に保存できませんでした", error: error)
    }
  }

  /// 保存先が別ボリュームだとmoveItemはファイル全体のコピーになるので、MainActorを止めないよう外で行う
  @concurrent
  private nonisolated static func moveRecording(
    _ source: URL, into directory: URL, baseName: String
  ) async throws -> URL {
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      let destination = OutputFileName.uniqueURL(in: directory, baseName: baseName) {
        fileManager.fileExists(atPath: $0.path)
      }
      try fileManager.moveItem(at: source, to: destination)
      return destination
    } catch {
      // ファイル操作のエラーはlocalizedDescriptionを作る時にエラーが持つpathの属性を取得するので、MainActorに返す前に文字列にする
      throw DescribedError(errorDescription: error.localizedDescription)
    }
  }

  /// 録画・トリミングの保存を終えた時に、成否に関わらず1回だけ呼ぶ
  private func endSession(errorMessage: String? = nil, error: (any Error)? = nil) {
    state = .idle
    if let errorMessage {
      showError(errorMessage, error)
    }
    // .terminateLaterを返した後は、replyで終了を再開しないといけない
    if isTerminating {
      NSApp.reply(toApplicationShouldTerminate: true)
    } else if smokeRecordSeconds != nil {
      NSApp.terminate(nil)
    }
  }

  private func showError(_ message: String, _ error: (any Error)?) {
    logger.error("\(message): \(error?.localizedDescription ?? "", privacy: .public)")
    if smokeRecordSeconds != nil { return }
    NSApp.activate()
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = message
    alert.informativeText = error?.localizedDescription ?? ""
    alert.runModal()
  }

  // MARK: - Trimming

  @objc private func trimClicked() {
    guard case .idle = state else { return }
    let panel = NSOpenPanel()
    panel.message = "トリミングするmp4を選んでください。トリミングすると元のファイルを上書きします"
    panel.prompt = "開く"
    panel.allowedContentTypes = [.mpeg4Movie]
    // ファイルのURLを渡すと、そのファイルを選択した状態で開く。ファイルが消えていても親フォルダを開く
    panel.directoryURL = lastSavedURL ?? saveDirectory
    state = .preparingTrim
    NSApp.activate()
    let response = panel.runModal()
    guard response == .OK, let url = panel.url else {
      state = .idle
      return
    }
    Task {
      do {
        openTrimWindow(url, videoSize: try await VideoTrimmer.trimmableVideoSize(of: url))
      } catch {
        state = .idle
        showError("\(url.lastPathComponent)をトリミングできません", error)
      }
    }
  }

  private func openTrimWindow(_ url: URL, videoSize: CGSize) {
    let window = TrimWindow(url: url, videoSize: videoSize) { [weak self] outcome in
      self?.trimWindowFinished(url, outcome)
    }
    state = .trimming(window)
    window.show()
  }

  private func trimWindowFinished(_ url: URL, _ outcome: TrimWindow.Outcome) {
    switch outcome {
    case .cancelled:
      state = .idle
    case .failed(let error):
      state = .idle
      showError("\(url.lastPathComponent)を開けませんでした", error)
    case .selected(let range):
      state = .savingTrim
      Task {
        do {
          let result = try await Self.replaceWithTrimmed(url, range: range)
          logger.info("trimmed \(result.path, privacy: .public)")
          lastSavedURL = result
          NSWorkspace.shared.activateFileViewerSelecting([result])
          endSession()
        } catch {
          endSession(errorMessage: "トリミングした動画を保存できませんでした", error: error)
        }
      }
    }
  }

  /// 書き出しに失敗しても元のファイルが残るよう、別の場所に書き出してから置き換える
  @concurrent
  private nonisolated static func replaceWithTrimmed(_ url: URL, range: CMTimeRange) async throws
    -> URL
  {
    let fileManager = FileManager.default
    let directory: URL
    do {
      directory = try temporaryDirectory(replacing: url)
    } catch {
      throw DescribedError(errorDescription: error.localizedDescription)
    }
    let trimmedURL = directory.appendingPathComponent(url.lastPathComponent)
    do {
      try await VideoTrimmer.trim(source: url, range: range, to: trimmedURL)
    } catch {
      try? fileManager.removeItem(at: directory)
      throw DescribedError(errorDescription: error.localizedDescription)
    }
    do {
      let result = try fileManager.replaceItemAt(url, withItemAt: trimmedURL) ?? url
      try? fileManager.removeItem(at: directory)
      return result
    } catch {
      // 置き換えに失敗すると、元のファイルがこの一時ディレクトリに移っている事があるので消さない
      var message = "\(error.localizedDescription)\n一時フォルダ: \(directory.path)"
      // このkeyはFoundationに定数として無い
      if let original = (error as NSError).userInfo["NSFileOriginalItemLocationKey"] as? URL {
        message += "\n元のファイル: \(original.path)"
      }
      throw DescribedError(errorDescription: message)
    }
  }

  /// replaceItemAtは同じボリューム上のファイルでしか置き換えられない。OSの一時ディレクトリを使えなければ、元のファイルの隣に一意な名前のディレクトリを作るようドキュメントが勧めている
  private nonisolated static func temporaryDirectory(replacing url: URL) throws -> URL {
    let fileManager = FileManager.default
    if let directory = try? fileManager.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
    {
      return directory
    }
    let directory = url.deletingLastPathComponent()
      .appendingPathComponent(".WakuVideo-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
  }

  // MARK: - Smoke test

  private func runSmokeTest() {
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
  }
}
