// AutoRaise & Launcher — 显式入口
// 绕过 @main/@NSApplicationMain 在所有 Swift/Xcode 版本中的不确定性
// 2026-11-01 coderLiu

import Cocoa

autoreleasepool {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}