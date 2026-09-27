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
}
