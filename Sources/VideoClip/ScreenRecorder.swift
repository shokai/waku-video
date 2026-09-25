import AVFoundation
import OSLog
import ScreenCaptureKit
import VideoClipCore

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

  var errorDescription: String? {
    switch self {
    case .displayNotFound: "録画するディスプレイが見つかりません"
    case .noFrames: "画面を1フレームも取得できませんでした"
    }
  }
}

private let logger = Logger(subsystem: "org.shokai.VideoClip", category: "ScreenRecorder")

/// SCStreamは非Sendableなので、MainActorから直接触らずにこのclassの中だけで扱う。
/// 生成後に状態を変えないので@unchecked Sendableにしている
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

  /// onStreamStoppedは、システムの「共有を停止」やディスプレイの切断でstreamが止まった時に呼ばれる
  static func start(
    _ request: RecordingRequest,
    onStreamStopped: @escaping @Sendable (any Error) -> Void
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
      url: request.outputURL, size: request.outputSize, onStreamStopped: onStreamStopped)
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
    let endTime = CMClockGetTime(CMClockGetHostTimeClock())
    do {
      try await stream.stopCapture()
    } catch {
      logger.info("stopCapture: \(String(describing: error), privacy: .public)")
    }
    try await writer.finish(at: endTime)
  }
}

/// AVAssetWriterの状態は全てqueueの上でだけ触るので、@unchecked Sendableにしている
private final class FrameWriter: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
  let queue = DispatchQueue(label: "org.shokai.VideoClip.writer")
  private let assetWriter: AVAssetWriter
  private let input: AVAssetWriterInput
  private let onStreamStopped: @Sendable (any Error) -> Void
  private var isStarted = false
  private var isFinished = false
  private var lastSample: CMSampleBuffer?

  init(url: URL, size: PixelSize, onStreamStopped: @escaping @Sendable (any Error) -> Void) throws {
    assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
    // moovをファイル先頭に置き、ダウンロードし終わる前に再生を始められるようにする
    assetWriter.shouldOptimizeForNetworkUse = true
    input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: size.width,
        AVVideoHeightKey: size.height,
        AVVideoColorPropertiesKey: [
          AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
          AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
          AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
        AVVideoCompressionPropertiesKey: [
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
          AVVideoExpectedSourceFrameRateKey: 30,
          AVVideoMaxKeyFrameIntervalDurationKey: 2,
          AVVideoAllowFrameReorderingKey: false,
        ],
      ])
    input.expectsMediaDataInRealTime = true
    assetWriter.add(input)
    self.onStreamStopped = onStreamStopped
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, !isFinished, Self.isComplete(sampleBuffer) else { return }
    if !isStarted {
      guard assetWriter.startWriting() else {
        logger.error(
          "startWriting failed: \(String(describing: self.assetWriter.error), privacy: .public)")
        isFinished = true
        return
      }
      assetWriter.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
      isStarted = true
    }
    guard input.isReadyForMoreMediaData else { return }
    if input.append(sampleBuffer) {
      lastSample = sampleBuffer
    } else {
      logger.error("append failed: \(String(describing: self.assetWriter.error), privacy: .public)")
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    logger.error("stream stopped: \(String(describing: error), privacy: .public)")
    onStreamStopped(error)
  }

  func finish(at endTime: CMTime) async throws {
    let hasFrames = await withCheckedContinuation { continuation in
      queue.async {
        self.isFinished = true
        guard self.isStarted, let last = self.lastSample else {
          continuation.resume(returning: false)
          return
        }
        let end = max(endTime, last.presentationTimeStamp)
        // ScreenCaptureKitは画面が変化した時しかframeを出さないので、そのままだと止める直前の静止時間が動画から欠ける。
        // 最後のframeを停止時刻に複製して、動画の長さを録画した時間に合わせる
        if end > last.presentationTimeStamp, self.input.isReadyForMoreMediaData,
          let tail = try? CMSampleBuffer(
            copying: last,
            withNewTiming: [
              CMSampleTimingInfo(
                duration: .invalid, presentationTimeStamp: end, decodeTimeStamp: .invalid)
            ])
        {
          self.input.append(tail)
        }
        self.input.markAsFinished()
        self.assetWriter.endSession(atSourceTime: end)
        self.lastSample = nil
        continuation.resume(returning: true)
      }
    }
    guard hasFrames else {
      if isStarted { assetWriter.cancelWriting() }
      throw RecorderError.noFrames
    }
    await assetWriter.finishWriting()
    if assetWriter.status == .failed {
      throw assetWriter.error ?? RecorderError.noFrames
    }
  }

  /// 画面に変化が無い間はimage bufferを持たないidle等のframeも届くので、completeだけを書く
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
