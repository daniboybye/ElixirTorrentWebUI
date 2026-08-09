import AppKit
import Foundation

let arguments = CommandLine.arguments

if let exitCode = LauncherCLI.handle(arguments: arguments) {
    exit(exitCode)
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
