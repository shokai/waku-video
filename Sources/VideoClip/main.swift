import AppKit

// NSApplication.delegateはweak参照なので、controllerをglobalに保持する
let controller = AppController()
let app = NSApplication.shared
app.delegate = controller
app.run()
