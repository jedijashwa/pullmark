import ApplicationServices
import Foundation

// Accessibility driver — acts on an app's UI semantically, with the app
// backgrounded and without touching the real cursor.
//
// Usage:
//   swift ax.swift <pid> menu <Menu> <Item> [<Subitem>]   AXPress a menu item
//   swift ax.swift <pid> press <title>                    AXPress a control by title
//   swift ax.swift <pid> list [<depth>]                   dump actionable elements

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard AXIsProcessTrusted() else {
    fail("error: this process lacks Accessibility permission (System Settings > Privacy & Security > Accessibility) — grant it to the terminal/session running this script.")
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
    fail("usage: swift ax.swift <pid> menu <Menu> <Item> [<Subitem>] | press <title> | list [<depth>]")
}
let app = AXUIElementCreateApplication(pid)

// MARK: - AX helpers

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func title(_ element: AXUIElement) -> String {
    (attribute(element, kAXTitleAttribute) as? String) ?? ""
}

func description(_ element: AXUIElement) -> String {
    (attribute(element, kAXDescriptionAttribute) as? String) ?? ""
}

func role(_ element: AXUIElement) -> String {
    (attribute(element, kAXRoleAttribute) as? String) ?? ""
}

func frame(_ element: AXUIElement) -> CGRect {
    guard let value = attribute(element, "AXFrame"),
          CFGetTypeID(value) == AXValueGetTypeID() else { return .null }
    var rect = CGRect.null
    AXValueGetValue(value as! AXValue, .cgRect, &rect)
    return rect
}

func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

func press(_ element: AXUIElement) {
    let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard error == .success else { fail("error: AXPress failed (AXError \(error.rawValue))") }
}

/// A human-usable label for matching and listing: title, else description.
func label(_ element: AXUIElement) -> String {
    let t = title(element)
    return t.isEmpty ? description(element) : t
}

// MARK: - commands

switch args[2] {
case "menu":
    let path = Array(args.dropFirst(3))
    guard !path.isEmpty else { fail("usage: swift ax.swift <pid> menu <Menu> <Item> [<Subitem>]") }
    guard let menuBar = attribute(app, kAXMenuBarAttribute),
          CFGetTypeID(menuBar) == AXUIElementGetTypeID() else {
        fail("error: no menu bar for pid \(pid) (app still launching, or not a regular app)")
    }
    var current = menuBar as! AXUIElement
    for (index, name) in path.enumerated() {
        // A menu-bar item or menu item wraps its entries in a single AXMenu child.
        var candidates = children(current)
        if candidates.count == 1, role(candidates[0]) == "AXMenu" {
            candidates = children(candidates[0])
        }
        let match = candidates.first { title($0).caseInsensitiveCompare(name) == .orderedSame }
            ?? candidates.first { title($0).range(of: name, options: .caseInsensitive) != nil }
        guard let match else {
            let available = candidates.map(title).filter { !$0.isEmpty }.joined(separator: ", ")
            fail("error: no menu item '\(name)' here; available: \(available)")
        }
        if index == path.count - 1 {
            press(match)
            print("pressed: \(path.joined(separator: " > "))")
        } else {
            current = match
        }
    }

case "press":
    let name = args.dropFirst(3).joined(separator: " ")
    guard !name.isEmpty else { fail("usage: swift ax.swift <pid> press <title>") }
    guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else {
        fail("error: no windows for pid \(pid)")
    }
    // Breadth-first over every window; collect pressable elements, then prefer
    // an exact (case-insensitive) label match over a substring match.
    var queue = windows
    var visited = 0
    var exact: AXUIElement?
    var loose: AXUIElement?
    while !queue.isEmpty, visited < 20_000, exact == nil {
        let element = queue.removeFirst()
        visited += 1
        if actions(element).contains(kAXPressAction) {
            for candidate in [title(element), description(element)] where !candidate.isEmpty {
                if candidate.caseInsensitiveCompare(name) == .orderedSame { exact = element }
                else if loose == nil, candidate.range(of: name, options: .caseInsensitive) != nil { loose = element }
            }
        }
        queue.append(contentsOf: children(element))
    }
    guard let target = exact ?? loose else {
        fail("error: no pressable element titled '\(name)' (searched \(visited) elements; try `ax.swift \(pid) list` to discover targets)")
    }
    // Capture everything to report BEFORE pressing: the press often
    // re-renders the UI and destroys the node, and querying a destroyed
    // AXUIElement can SIGTRAP inside the AX runtime.
    let pressedRole = role(target)
    let pressedLabel = label(target)
    let box = frame(target)
    press(target)
    print("pressed: \(pressedRole) \"\(pressedLabel)\" at (\(Int(box.midX)), \(Int(box.midY)))")

case "list":
    let maxDepth = args.count > 3 ? (Int(args[3]) ?? 8) : 8
    guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else {
        fail("error: no windows for pid \(pid)")
    }
    var queue: [(AXUIElement, Int)] = windows.map { ($0, 0) }
    var visited = 0
    while !queue.isEmpty, visited < 20_000 {
        let (element, depth) = queue.removeFirst()
        visited += 1
        if actions(element).contains(kAXPressAction) {
            let box = frame(element)
            let bounds = box.isNull ? "?" : "\(Int(box.origin.x)) \(Int(box.origin.y)) \(Int(box.width)) \(Int(box.height))"
            print("\(role(element)) \"\(label(element))\" \(bounds)")
        }
        if depth < maxDepth {
            queue.append(contentsOf: children(element).map { ($0, depth + 1) })
        }
    }

default:
    fail("error: unknown command '\(args[2])' (expected menu, press, or list)")
}
