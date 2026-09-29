import AppKit

let args = CommandLine.arguments
func argValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let app = NSApplication.shared
let controller = AppController(profile: argValue("--profile") ?? "default", windowed: args.contains("--windowed"))
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
