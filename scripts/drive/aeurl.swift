import AppKit
import Foundation

// Usage: swift aeurl.swift <pid> <url> — deliver a GetURL ('GURL')
// AppleEvent to the process with that pid. The pid-addressed sibling of
// aeopen.swift for pullmark:// links: `open <url>` resolves the handler
// through Launch Services by bundle id, which can hit the INSTALLED
// copy instead of the capture instance. Addressing by pid can't.
guard CommandLine.arguments.count == 3,
      let pid = pid_t(CommandLine.arguments[1])
else {
    FileHandle.standardError.write(Data("usage: swift aeurl.swift <pid> <url>\n".utf8))
    exit(1)
}
let urlString = CommandLine.arguments[2]
let target = NSAppleEventDescriptor(processIdentifier: pid)
let event = NSAppleEventDescriptor(
    eventClass: AEEventClass(kInternetEventClass),
    eventID: AEEventID(kAEGetURL),
    targetDescriptor: target,
    returnID: AEReturnID(kAutoGenerateReturnID),
    transactionID: AETransactionID(kAnyTransactionID))
event.setParam(NSAppleEventDescriptor(string: urlString), forKeyword: keyDirectObject)
do {
    try event.sendEvent(options: [.noReply], timeout: 10)
    print("sent GURL \(urlString) → pid \(pid)")
} catch {
    FileHandle.standardError.write(Data("error: sendEvent failed: \(error)\n".utf8))
    exit(1)
}
