import AppKit
import Foundation

// Usage: swift aeopen.swift <pid> <path> — deliver an open-document
// ('odoc') AppleEvent to the process with that pid.
//
// This exists because every other delivery route resolves the TARGET
// through Launch Services by bundle id, and with two copies of the
// app alive (/Applications + dist) LS sometimes launches a THIRD
// instance for the document instead of handing it to the one under
// test. Addressing the event by pid skips LS entirely, works with
// the app backgrounded, and is safe to run against many instances
// in parallel.
guard CommandLine.arguments.count == 3,
      let pid = pid_t(CommandLine.arguments[1])
else {
    FileHandle.standardError.write(Data("usage: swift aeopen.swift <pid> <path>\n".utf8))
    exit(1)
}
let url = URL(fileURLWithPath: CommandLine.arguments[2])
let target = NSAppleEventDescriptor(processIdentifier: pid)
let event = NSAppleEventDescriptor(
    eventClass: AEEventClass(kCoreEventClass),
    eventID: AEEventID(kAEOpenDocuments),
    targetDescriptor: target,
    returnID: AEReturnID(kAutoGenerateReturnID),
    transactionID: AETransactionID(kAnyTransactionID))
let list = NSAppleEventDescriptor.list()
list.insert(NSAppleEventDescriptor(fileURL: url), at: 1)
event.setParam(list, forKeyword: keyDirectObject)
do {
    try event.sendEvent(options: [.noReply], timeout: 10)
    print("sent odoc \(url.path) → pid \(pid)")
} catch {
    FileHandle.standardError.write(Data("error: sendEvent failed: \(error)\n".utf8))
    exit(1)
}
