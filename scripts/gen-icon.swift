import Foundation

let script = URL(fileURLWithPath: #filePath)
let kit = script.deletingLastPathComponent().appendingPathComponent("icons/build.py")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["python3", kit.path] + (CommandLine.arguments.count > 1 ? ["--output", CommandLine.arguments[1]] : [])
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
