import Foundation
import Testing

@testable import WakuVideoCore

struct OutputFileNameTests {
  @Test func baseNameUsesGivenTimeZone() throws {
    // 2026-09-25 09:30:00 UTC
    let date = Date(timeIntervalSince1970: 1_790_328_600)
    let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
    #expect(OutputFileName.baseName(for: date, timeZone: tokyo) == "2026-09-25 18.30.00")
  }

  @Test func uniqueURLAppendsIndexOnCollision() {
    let directory = URL(fileURLWithPath: "/tmp/desktop")
    let taken: Set<String> = ["a.mp4", "a (2).mp4"]
    let url = OutputFileName.uniqueURL(in: directory, baseName: "a") {
      taken.contains($0.lastPathComponent)
    }
    #expect(url.path == "/tmp/desktop/a (3).mp4")
  }

  @Test func uniqueURLWithoutCollision() {
    let url = OutputFileName.uniqueURL(in: URL(fileURLWithPath: "/tmp"), baseName: "a") { _ in
      false
    }
    #expect(url.path == "/tmp/a.mp4")
  }

  private func trimmedName(_ fileName: String, taken: Set<String> = []) -> String {
    OutputFileName.trimmedURL(for: URL(fileURLWithPath: "/tmp/desktop/\(fileName)")) {
      #expect($0.deletingLastPathComponent().path == "/tmp/desktop")
      return taken.contains($0.lastPathComponent)
    }.lastPathComponent
  }

  @Test func trimmedURLAppendsVersion() {
    #expect(trimmedName("2026-09-25 18.30.00.mp4") == "2026-09-25 18.30.00_2.mp4")
    #expect(trimmedName("2026-09-25 18.30.00 (2).mp4") == "2026-09-25 18.30.00 (2)_2.mp4")
  }

  @Test func trimmedURLSkipsTakenVersions() {
    #expect(trimmedName("a.mp4", taken: ["a_2.mp4", "a_3.mp4"]) == "a_4.mp4")
  }

  @Test func trimmedURLIncrementsTrailingVersion() {
    #expect(trimmedName("a_2.mp4") == "a_3.mp4")
    #expect(trimmedName("a_2.mp4", taken: ["a_3.mp4"]) == "a_4.mp4")
    #expect(trimmedName("IMG_1234.mp4") == "IMG_1235.mp4")
    #expect(trimmedName("a_007.mp4") == "a_8.mp4")
    #expect(trimmedName("a_b_2.mp4") == "a_b_3.mp4")
  }

  @Test func trimmedURLTreatsNonNumericSuffixAsName() {
    #expect(trimmedName("a_b.mp4") == "a_b_2.mp4")
    #expect(trimmedName("a_.mp4") == "a__2.mp4")
    #expect(trimmedName("a_2b.mp4") == "a_2b_2.mp4")
    #expect(trimmedName("a_+2.mp4") == "a_+2_2.mp4")
    #expect(trimmedName("a_٣.mp4") == "a_٣_2.mp4")
    #expect(trimmedName("a_99999999999999999999.mp4") == "a_99999999999999999999_2.mp4")
    #expect(trimmedName("a_9223372036854775807.mp4") == "a_9223372036854775807_2.mp4")
  }

  @Test func trimmedURLStopsAtIntMax() {
    #expect(
      trimmedName(
        "a_9223372036854775805.mp4",
        taken: ["a_9223372036854775806.mp4", "a_9223372036854775807.mp4"])
        == "a_9223372036854775807.mp4")
  }

  @Test func candidatesAreFilesEvenIfFolderWithSameNameExists() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("OutputFileNameTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["a", "a_2"] {
      try FileManager.default.createDirectory(
        at: directory.appendingPathComponent(name, isDirectory: true),
        withIntermediateDirectories: true)
    }

    let unique = OutputFileName.uniqueURL(in: directory, baseName: "a") { _ in false }
    #expect(unique.lastPathComponent == "a.mp4")
    #expect(!unique.hasDirectoryPath)

    let trimmed = OutputFileName.trimmedURL(for: directory.appendingPathComponent("a.mp4")) {
      _ in false
    }
    #expect(trimmed.lastPathComponent == "a_2.mp4")
    #expect(!trimmed.hasDirectoryPath)
  }

  @Test func trimmedURLAlwaysUsesMP4Extension() {
    #expect(trimmedName("a.MP4") == "a_2.mp4")
    #expect(trimmedName("a.m4v") == "a_2.mp4")
  }
}
