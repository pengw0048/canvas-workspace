// Prints pasteboard types and writes image/text representations: swift scripts/pbdump.swift <out-prefix>
import AppKit
let pb = NSPasteboard.general
let prefix = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/pb"
for t in pb.types ?? [] { print(t.rawValue, pb.data(forType: t)?.count ?? 0) }
if let d = pb.data(forType: .png) { try? d.write(to: URL(fileURLWithPath: prefix + ".png")); print("wrote", prefix + ".png") }
if let s = pb.string(forType: .string) { print("string:", s) }
if let u = pb.string(forType: .fileURL) { print("fileURL:", u) }
