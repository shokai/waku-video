import AVFoundation

public enum TrimError: LocalizedError {
  case noVideoTrack
  case hasAudioTrack
  case unsupportedTracks
  case noFrames
  case readFailed
  case writeFailed

  public var errorDescription: String? {
    switch self {
    case .noVideoTrack: "映像の無いファイルはトリミングできません"
    case .hasAudioTrack: "音声付きの動画はトリミングできません"
    case .unsupportedTracks: "映像トラックを1本だけ持つ動画しかトリミングできません"
    case .noFrames: "トリミングする範囲にフレームがありません"
    case .readFailed: "動画を読み込めませんでした"
    case .writeFailed: "動画の書き出しに失敗しました"
    }
  }
}

public enum VideoTrimmer {
  /// トリミングできる動画なら、回転を反映した表示上の大きさを返す
  @concurrent
  public static func trimmableVideoSize(of url: URL) async throws -> CGSize {
    let tracks = try await AVURLAsset(url: url).load(.tracks)
    if tracks.contains(where: { $0.mediaType == .audio }) { throw TrimError.hasAudioTrack }
    guard let track = tracks.first(where: { $0.mediaType == .video }) else {
      throw TrimError.noVideoTrack
    }
    // trimは映像トラックを1本だけ書き出すので、他のトラックはトリミングした動画から抜け落ちる
    guard tracks.count == 1 else { throw TrimError.unsupportedTracks }
    let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
    let size = naturalSize.applying(transform)
    return CGSize(width: abs(size.width), height: abs(size.height))
  }

  /// 最初の映像トラックだけを書き出す
  @concurrent
  public static func trim(source: URL, range: CMTimeRange, to destination: URL) async throws {
    let asset = AVURLAsset(url: source)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw TrimError.noVideoTrack
    }
    let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        // HDR等の入力を、8bitに落とすのと同時にBT.709へ変換し、階調の劣化を抑える
        AVVideoColorPropertiesKey: VideoEncoding.colorProperties,
      ])
    output.alwaysCopiesSampleData = false
    reader.add(output)

    let sourceSize = PixelSize(
      width: Int(naturalSize.width.rounded()), height: Int(naturalSize.height.rounded()))
    let outputSize = OutputSizing.outputSize(pointSize: naturalSize, scale: 1)
    var settings = VideoEncoding.outputSettings(size: outputSize)
    if outputSize != sourceSize {
      // 録画のpreservesAspectRatio = falseと揃え、縮小で縦横比が僅かにずれても端に帯を入れない
      settings[AVVideoScalingModeKey] = AVVideoScalingModeResize
    }
    let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
    // moovをファイル先頭に置き、ダウンロードし終わる前に再生を始められるようにする
    writer.shouldOptimizeForNetworkUse = true
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    input.transform = transform
    writer.add(input)

    // reader.timeRangeを使うと、startの時点で表示中のframeが返ってくる保証が無いので、先頭から読む
    guard reader.startReading() else { throw reader.error ?? TrimError.readFailed }
    defer { reader.cancelReading() }
    guard writer.startWriting() else { throw writer.error ?? TrimError.writeFailed }
    writer.startSession(atSourceTime: range.start)

    var timeline = TrimTimeline<CMSampleBuffer>(range: range)
    var hasAppended = false
    do {
      while !timeline.isFinished, let sample = output.copyNextSampleBuffer() {
        // AVAssetReaderはmarker-onlyのsample bufferを返す事がある
        guard sample.numSamples > 0 else { continue }
        for frame in timeline.push(sample, at: sample.presentationTimeStamp) {
          try await append(frame, to: input, of: writer)
          hasAppended = true
        }
      }
      if reader.status == .failed { throw reader.error ?? TrimError.readFailed }
      for frame in timeline.finish() {
        try await append(frame, to: input, of: writer)
        hasAppended = true
      }
      guard hasAppended else { throw TrimError.noFrames }
    } catch {
      writer.cancelWriting()
      throw error
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: range.end)
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? TrimError.writeFailed }
  }

  private static func append(
    _ frame: TrimTimeline<CMSampleBuffer>.Output, to input: AVAssetWriterInput,
    of writer: AVAssetWriter
  ) async throws {
    var sample = frame.frame
    if sample.presentationTimeStamp != frame.time {
      let timing = CMSampleTimingInfo(
        duration: .invalid, presentationTimeStamp: frame.time, decodeTimeStamp: .invalid)
      sample = try CMSampleBuffer(copying: sample, withNewTiming: [timing])
    }
    while !input.isReadyForMoreMediaData {
      // writerが失敗するとreadinessがfalseのままになるので、statusを見て抜ける
      if writer.status == .failed { throw writer.error ?? TrimError.writeFailed }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard input.append(sample) else { throw writer.error ?? TrimError.writeFailed }
  }
}
