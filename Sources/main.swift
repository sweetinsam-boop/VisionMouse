import AppKit
import Foundation

if CommandLine.arguments.contains("--self-test") {
    exit(SelfTestRunner.runAll())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
