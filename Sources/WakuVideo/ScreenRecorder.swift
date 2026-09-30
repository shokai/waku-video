import AVFoundation
import OSLog
import ScreenCaptureKit
import WakuVideoCore

struct RecordingRequest: Sendable {
  var displayID: CGDirectDisplayID
  /// ディスプレイローカルの左上原点、point単位
  var sourceRect: CGRect
  var outputSize: PixelSize
  var outputURL: URL
}

enum RecorderError: LocalizedError {
  case displayNotFound
  case noFrames
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .displayNotFound: "録画するディスプレイが見つかりません"
    case .noFrames: "画面を1フレームも取得できませんでした"
    case .writeFailed: "動画の書き出しに失敗しました"
    }
  }
}

private let logger = Logger(subsystem: "org.shokai.WakuVideo", category: "ScreenRecorder")

/// SCStreamは非Sendableなので、MainActorから直接触らずにこのclassの中だけで扱う。
/// startで生成した後、AppControllerがstop()を1回だけ呼ぶ前提で@unchecked Sendableにしている
final class ScreenRecorder: @unchecked Sendable {
  private let stream: SCStream
  private let writer: FrameWriter

  private init(stream: SCStream, writer: FrameWriter) {
    self.stream = stream
    self.writer = writer
  }

  /// macOS 15以降の画面収録の定期再確認ダイアログを、範囲選択より前に出させる
  static func preflight() async throws {
    _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
  }

  /// onInterruptedは、システムの「共有を停止」やディスプレイの切断でstreamが止まった時と、書き出しに失敗した時に呼ばれる
  static func start(
    _ request: RecordingRequest,
    onInterrupted: @escaping @Sendable (any Error) -> Void
  ) async throws -> ScreenRecorder {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == request.displayID }) else {
      throw RecorderError.displayNotFound
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])

    let config = SCStreamConfiguration()
    config.sourceRect = request.sourceRect
    config.width = request.outputSize.width
    config.height = request.outputSize.height
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.showsCursor = true
    config.captureResolution = .best
    config.colorSpaceName = CGColorSpace.sRGB
    // OutputSizingで縮小した時に縦横比が僅かにずれても、端に帯を入れずに引き伸ばす
    config.preservesAspectRatio = false

    let writer = try FrameWriter(
      url: request.outputURL, size: request.outputSize, onInterrupted: onInterrupted)
    let stream = SCStream(filter: filter, configuration: config, delegate: writer)
    try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)

    logger.info(
      "start display=\(request.displayID) sourceRect=\(String(describing: request.sourceRect), privacy: .public) output=\(request.outputSize.width)x\(request.outputSize.height)"
    )
    try await stream.startCapture()
    return ScreenRecorder(stream: stream, writer: writer)
  }

  /// 書き出しが終わるまで待つ。streamが既に止まっていても呼んでよい
  func stop() async throws {
    // sample bufferのPTSと同じ時間軸で停止時刻を取る
    let endTime = CMClockGetTime(stream.synchronizationClock ?? CMClockGetHostTimeClock())
    do {
      try await stream.stopCapture()
    } catch {
      logger.info("stopCapture: \(String(describing: error), privacy: .public)")
    }
    try await writer.finish(at: endTime)
  }
}

/// sample bufferのappendまでの可変状態は、全てqueueの上でだけ触るので@unchecked Sendableにしている
private final class FrameWriter: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
  private static let readyTimeout: TimeInterval = 0.5

  let queue = DispatchQueue(label: "org.shokai.WakuVideo.writer")
  private let assetWriter: AVAssetWriter
  private let input: AVAssetWriterInput
  private let onInterrupted: @Sendable (any Error) -> Void
  private var isFinished = false
  private var failure: (any Error)?
  /// ScreenCaptureKitは画面が変化した時しかcompleteなframeを出さないので、encoderが混んでいて書けなかった最新のframeを次の機会まで持っておく
  private var pendingSample: CMSampleBuffer?
  private var lastAppendedSample: CMSampleBuffer?

  init(url: URL, size: PixelSize, onInterrupted: @escaping @Sendable (any Error) -> Void) throws {
    assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
    // moovをファイル先頭に置き、ダウンロードし終わる前に再生を始められるようにする
    assetWriter.shouldOptimizeForNetworkUse = true
    input = AVAssetWriterInput(
      mediaType: .video, outputSettings: VideoEncoding.outputSettings(size: size))
    input.expectsMediaDataInRealTime = true
    assetWriter.add(input)
    self.onInterrupted = onInterrupted
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, !isFinished else { return }
    // append成功後にwriterが非同期に失敗すると、readinessがfalseのままになるだけなので、statusを見て気付く
    if assetWriter.status == .failed {
      fail(assetWriter.error ?? RecorderError.writeFailed)
      return
    }
    if Self.isComplete(sampleBuffer) {
      pendingSample = sampleBuffer
    }
    // 画面が静止している間もidleなframeが届くので、書けなかったframeはその時に書く
    appendPendingSample()
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    logger.error("stream stopped: \(String(describing: error), privacy: .public)")
    onInterrupted(error)
  }

  func finish(at endTime: CMTime) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      queue.async {
        do {
          try self.closeInput(at: endTime)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
    await assetWriter.finishWriting()
    guard assetWriter.status == .completed else {
      throw assetWriter.error ?? RecorderError.writeFailed
    }
  }

  private func appendPendingSample() {
    guard let sample = pendingSample else { return }
    // isReadyForMoreMediaDataはstartWritingするまでfalseのままなので、先に書き込みを始める
    if assetWriter.status == .unknown {
      guard assetWriter.startWriting() else {
        fail(assetWriter.error ?? RecorderError.writeFailed)
        return
      }
      assetWriter.startSession(atSourceTime: sample.presentationTimeStamp)
    }
    guard input.isReadyForMoreMediaData else { return }
    guard input.append(sample) else {
      fail(assetWriter.error ?? RecorderError.writeFailed)
      return
    }
    lastAppendedSample = sample
    pendingSample = nil
  }

  private func fail(_ error: any Error) {
    guard failure == nil else { return }
    logger.error("writer failed: \(String(describing: error), privacy: .public)")
    failure = error
    isFinished = true
    onInterrupted(error)
  }

  private func closeInput(at endTime: CMTime) throws {
    defer {
      isFinished = true
      pendingSample = nil
      lastAppendedSample = nil
    }
    if let failure { throw failure }
    if assetWriter.status == .failed { throw assetWriter.error ?? RecorderError.writeFailed }
    if pendingSample != nil, waitUntilReady() {
      appendPendingSample()
      if let failure { throw failure }
    }
    guard let last = lastAppendedSample else {
      if assetWriter.status == .writing { assetWriter.cancelWriting() }
      throw RecorderError.noFrames
    }

    // encoderが詰まったままで最新のframeを書けなければ、そのframeと末尾の複製は諦めて保存する
    let end = max(endTime, last.presentationTimeStamp)
    if pendingSample != nil {
      logger.error("dropped the latest frame because the encoder was not ready")
    } else if end > last.presentationTimeStamp {
      // 最後のframeを停止時刻に複製して、止める直前の静止時間も動画に残す
      let timing = CMSampleTimingInfo(
        duration: .invalid, presentationTimeStamp: end, decodeTimeStamp: .invalid)
      if let tail = try? CMSampleBuffer(copying: last, withNewTiming: [timing]), waitUntilReady() {
        guard input.append(tail) else { throw assetWriter.error ?? RecorderError.writeFailed }
      } else {
        logger.error("could not append the last frame again")
      }
    }
    input.markAsFinished()
    assetWriter.endSession(atSourceTime: end)
  }

  /// streamを止めた後にだけ呼ぶ。encoderが追い付くのを短時間だけ待ち、書けるようになったかを返す
  private func waitUntilReady() -> Bool {
    let deadline = Date().addingTimeInterval(Self.readyTimeout)
    while !input.isReadyForMoreMediaData, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    return input.isReadyForMoreMediaData
  }

  /// idle等のframeはimage bufferを持たないので、completeだけを書く
  private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let rawStatus = attachments.first?[.status] as? Int,
      let status = SCFrameStatus(rawValue: rawStatus)
    else { return false }
    return status == .complete
  }
}
