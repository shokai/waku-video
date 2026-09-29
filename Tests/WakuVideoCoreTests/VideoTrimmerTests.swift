import AVFoundation
import Testing

@testable import WakuVideoCore

private let size = PixelSize(width: 64, height: 48)

private func t(_ seconds: Double) -> CMTime {
  CMTime(seconds: seconds, preferredTimescale: 600)
}

private struct DecodedFrame {
  var time: Double
  var luma: UInt8
}

/// 録画と同じく、startSessionをhost timeのような大きな時刻にし、最後のframeをendに複製してendSessionする
private func makeRecordingLikeVideo(
  at url: URL, frames: [(gray: UInt8, time: Double)], end: Double
) async throws {
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = AVAssetWriterInput(
    mediaType: .video, outputSettings: VideoEncoding.outputSettings(size: size))
  input.expectsMediaDataInRealTime = false
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: size.width,
      kCVPixelBufferHeightKey as String: size.height,
    ])
  writer.add(input)
  try #require(writer.startWriting())
  writer.startSession(atSourceTime: t(frames[0].time))
  let last = try #require(frames.last)
  for frame in frames + [(gray: last.gray, time: end)] {
    let buffer = try makePixelBuffer(gray: frame.gray)
    while !input.isReadyForMoreMediaData {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(adaptor.append(buffer, withPresentationTime: t(frame.time)))
  }
  input.markAsFinished()
  writer.endSession(atSourceTime: t(end))
  await writer.finishWriting()
  try #require(writer.status == .completed)
}

private func makePixelBuffer(gray: UInt8) throws -> CVPixelBuffer {
  var buffer: CVPixelBuffer?
  CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_32BGRA, nil, &buffer)
  let pixelBuffer = try #require(buffer)
  CVPixelBufferLockBaseAddress(pixelBuffer, [])
  defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
  let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer))
  memset(base, Int32(gray), CVPixelBufferGetDataSize(pixelBuffer))
  return pixelBuffer
}

private func decodeFrames(of url: URL) async throws -> [DecodedFrame] {
  let asset = AVURLAsset(url: url)
  let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
  let reader = try AVAssetReader(asset: asset)
  let output = AVAssetReaderTrackOutput(
    track: track,
    outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ])
  reader.add(output)
  try #require(reader.startReading())
  var frames: [DecodedFrame] = []
  while let sample = output.copyNextSampleBuffer() {
    guard let image = sample.imageBuffer else { continue }
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let plane = try #require(CVPixelBufferGetBaseAddressOfPlane(image, 0))
    let center = CVPixelBufferGetBytesPerRowOfPlane(image, 0) * (size.height / 2) + size.width / 2
    frames.append(
      DecodedFrame(
        time: sample.presentationTimeStamp.seconds,
        luma: plane.load(fromByteOffset: center, as: UInt8.self)))
  }
  try #require(reader.status == .completed)
  return frames
}

private func expectTimes(_ frames: [DecodedFrame], _ expected: [Double]) {
  #expect(frames.count == expected.count, "\(frames.map(\.time))")
  for (frame, time) in zip(frames, expected) {
    #expect(abs(frame.time - time) < 0.002, "\(frames.map(\.time))")
  }
}

struct VideoTrimmerTests {
  @Test func trimsRecordingLikeVideo() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("VideoTrimmerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.mp4")
    let destination = directory.appendingPathComponent("trimmed.mp4")

    try await makeRecordingLikeVideo(
      at: source, frames: [(40, 100), (100, 100.5), (160, 102), (220, 102.1)], end: 104)
    let sourceFrames = try await decodeFrames(of: source)
    expectTimes(sourceFrames, [0, 0.5, 2, 2.1])

    try await VideoTrimmer.trim(
      source: source, range: CMTimeRange(start: t(1.2), end: t(3)), to: destination)

    let asset = AVURLAsset(url: destination)
    #expect(abs(try await asset.load(.duration).seconds - 1.8) < 0.002)
    let frames = try await decodeFrames(of: destination)
    expectTimes(frames, [0, 0.8, 0.9])
    // startの時点で表示中の100.5秒のframeから始まる。再エンコードで輝度が僅かにずれる
    for (frame, sourceFrame) in zip(frames, sourceFrames[1...3]) {
      #expect(abs(Int(frame.luma) - Int(sourceFrame.luma)) <= 4, "\(frames.map(\.luma))")
    }

    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let description = try #require(try await track.load(.formatDescriptions).first)
    #expect(description.mediaSubType == .h264)
    let extensions = description.extensions
    #expect(
      extensions[.colorPrimaries] == .colorPrimaries(.itu_R_709_2)
        && extensions[.transferFunction] == .transferFunction(.itu_R_709_2)
        && extensions[.yCbCrMatrix] == .yCbCrMatrix(.itu_R_709_2))
  }
}
