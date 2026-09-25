import AppKit
import CoreGraphics

@MainActor
enum Permissions {
  static func ensureScreenCapture() -> Bool {
    if CGPreflightScreenCaptureAccess() { return true }

    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = "画面収録の許可が必要です"
    alert.informativeText =
      "システム設定の「プライバシーとセキュリティ」→「画面とシステムオーディオの録音」でVideoClipを許可し、VideoClipを再起動してください。"
    alert.addButton(withTitle: "システム設定を開く")
    alert.addButton(withTitle: "キャンセル")
    guard alert.runModal() == .alertFirstButtonReturn else { return false }

    // 一度requestしないと、システム設定の一覧にVideoClipが表示されない
    CGRequestScreenCaptureAccess()
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    {
      NSWorkspace.shared.open(url)
    }
    return false
  }
}
