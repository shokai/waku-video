import Foundation
import Testing

@testable import VideoClipCore

struct SaveDirectoryTests {
  let desktop = URL(filePath: "/Users/test/Desktop", directoryHint: .isDirectory)

  @Test(arguments: [nil, ""])
  func fallsBackWhenUnset(path: String?) {
    #expect(SaveDirectory.url(fromPath: path, fallback: desktop) == desktop)
  }

  @Test func expandsTilde() {
    let url = SaveDirectory.url(fromPath: "~/Movies", fallback: desktop)
    #expect(url.path == NSHomeDirectory() + "/Movies")
  }

  @Test func keepsAbsolutePathAsDirectory() {
    let url = SaveDirectory.url(fromPath: "/Volumes/NAS/録画 clips", fallback: desktop)
    #expect(url.path == "/Volumes/NAS/録画 clips")
    #expect(url.hasDirectoryPath)
  }

  @Test func resolvesRelativePathAgainstCurrentDirectory() {
    let url = SaveDirectory.url(fromPath: "Movies", fallback: desktop)
    let expected = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "Movies")
    #expect(url.path == expected.path)
  }
}
