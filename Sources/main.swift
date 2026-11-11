import AppKit
import Foundation

if CommandLine.arguments.contains("--self-test") {
    exit(SelfTestRunner.runAll())
}
if let i = CommandLine.arguments.firstIndex(of: "--replay"), i + 1 < CommandLine.arguments.count {
    exit(ReplayRunner.run(path: CommandLine.arguments[i + 1]))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
