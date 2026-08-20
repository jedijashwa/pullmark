import CoreGraphics
import Foundation

// gmouse.swift <x> <y> <right|hold|button4|button5>
//
// Global mouse gestures the other scripts lack: right-click,
// press-and-hold (0.6 s), and the extra mouse buttons 4/5 that
// browsers (and PullMark) map to back/forward. Global tier: these move
// the real pointer and land on whatever is frontmost — batch them,
// warn the human, and park the cursor off-window before captures.
//
// Why global and not postToPid: pid-targeted mouse events never reach
// NSToolbar buttons (verified live 2026-08-20 — pclick on any toolbar
// button is silently dropped), so toolbar work needs the HID tap.
let args = CommandLine.arguments
guard args.count == 4, let x = Double(args[1]), let y = Double(args[2]) else {
    print("usage: gmouse.swift <x> <y> <right|hold|button4|button5>")
    exit(1)
}
let point = CGPoint(x: x, y: y)
let mode = args[3]

func post(_ type: CGEventType, _ button: CGMouseButton) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type,
                        mouseCursorPosition: point, mouseButton: button)!
    if button == .center {
        // "center" stands in for the extra buttons; set the real number.
        event.setIntegerValueField(.mouseEventButtonNumber,
                                   value: mode == "button4" ? 3 : 4)
    }
    event.post(tap: .cghidEventTap)
}

switch mode {
case "right":
    post(.rightMouseDown, .right)
    usleep(80_000)
    post(.rightMouseUp, .right)
case "hold":
    post(.leftMouseDown, .left)
    usleep(600_000)
    post(.leftMouseUp, .left)
case "button4", "button5":
    post(.otherMouseDown, .center)
    usleep(60_000)
    post(.otherMouseUp, .center)
default:
    print("unknown mode \(mode)")
    exit(1)
}
