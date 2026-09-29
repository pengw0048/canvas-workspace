// Input source helper: tis current | tis select <id>
import Carbon
let a = CommandLine.arguments
func sid(_ s: TISInputSource) -> String? { TISGetInputSourceProperty(s, kTISPropertyInputSourceID).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } }
if a[1] == "current" { print(sid(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) ?? "?") }
else if a[1] == "select" {
    let list = TISCreateInputSourceList([kTISPropertyInputSourceID as String: a[2]] as CFDictionary, false).takeRetainedValue() as! [TISInputSource]
    if let s = list.first { print(TISSelectInputSource(s) == noErr ? "selected" : "failed") } else { print("not found") }
}
