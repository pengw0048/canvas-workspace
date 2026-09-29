import AppKit

let args = CommandLine.arguments
func argValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if let dir = argValue("--write-iconset") {
    do { try AppIcon.writeIconset(to: dir); exit(0) } catch { print(error); exit(1) }
}
let app = NSApplication.shared
let controller = AppController(profile: argValue("--profile") ?? "default", windowed: args.contains("--windowed"))
app.delegate = controller
app.setActivationPolicy(.regular)
app.applicationIconImage = AppIcon.image
app.run()
