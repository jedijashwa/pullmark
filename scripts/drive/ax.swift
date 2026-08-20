import ApplicationServices
import Foundation

// Accessibility driver — acts on an app's UI semantically, with the app
// backgrounded and without touching the real cursor.
//
// Usage:
//   swift ax.swift <pid> menu <Menu> <Item> [<Subitem>]   AXPress a menu item
//   swift ax.swift <pid> menuitem <title>                 AXPress a menu item found anywhere in the menu bar
//   swift ax.swift <pid> menukey <char> <modifiers>       AXPress a menu item by keyboard equivalent
//   swift ax.swift <pid> press <title>                    AXPress a control by title
//   swift ax.swift <pid> sidebar-state                    print "visible" or "hidden"
//   swift ax.swift <pid> list [<depth>]                   dump actionable elements
//
// menuitem and menukey exist for localized runs (the screenshot
// generator's --lang matrix): menu/press match visible titles, which
// change with AppleLanguages. menuitem still takes a title — the
// caller resolves it from loc/<lang>.lproj — but doesn't need the
// menu-bar path, whose top-level names are system-localized. menukey
// is for SYSTEM items we can't resolve from loc/ (sidebar toggle,
// Settings, Quit): keyboard equivalents are language-independent.
// Modifiers: comma-separated shift/opt/ctrl/cmd, e.g. "ctrl,cmd".

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard AXIsProcessTrusted() else {
    fail("error: this process lacks Accessibility permission (System Settings > Privacy & Security > Accessibility) — grant it to the terminal/session running this script.")
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
    fail("usage: swift ax.swift <pid> menu <Menu> <Item> [<Subitem>] | menuitem <title> | menukey <char> <modifiers> | press <title> | sidebar-state | list [<depth>]")
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

func identifier(_ element: AXUIElement) -> String {
    (attribute(element, kAXIdentifierAttribute) as? String) ?? ""
}

/// Every pressable menu item in the menu bar, skipping the Apple menu
/// (system items there are never scene targets, and substring matches
/// against it would be hazardous). Breadth-first through submenus.
func menuBarItems() -> [AXUIElement] {
    guard let menuBar = attribute(app, kAXMenuBarAttribute),
          CFGetTypeID(menuBar) == AXUIElementGetTypeID() else {
        fail("error: no menu bar for pid \(pid) (app still launching, or not a regular app)")
    }
    var queue = Array(children(menuBar as! AXUIElement).dropFirst())  // drop Apple menu
    var items: [AXUIElement] = []
    var visited = 0
    while !queue.isEmpty, visited < 5_000 {
        let element = queue.removeFirst()
        visited += 1
        if role(element) == "AXMenuItem", !title(element).isEmpty {
            items.append(element)
        }
        queue.append(contentsOf: children(element))
    }
    return items
}

func pressMenuItem(_ item: AXUIElement, described: String) {
    let pressedTitle = title(item)  // capture before pressing (see `press`)
    press(item)
    print("pressed menu item: \"\(pressedTitle)\" (\(described))")
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

case "menuitem":
    let name = args.dropFirst(3).joined(separator: " ")
    guard !name.isEmpty else { fail("usage: swift ax.swift <pid> menuitem <title>") }
    let items = menuBarItems()
    let match = items.first { title($0).caseInsensitiveCompare(name) == .orderedSame }
        ?? items.first { title($0).range(of: name, options: .caseInsensitive) != nil }
    guard let match else {
        fail("error: no menu item titled '\(name)' anywhere in the menu bar (\(items.count) items searched)")
    }
    pressMenuItem(match, described: "matched '\(name)'")

case "menukey":
    guard args.count >= 5 else { fail("usage: swift ax.swift <pid> menukey <char> <modifiers>") }
    let char = args[3]
    var mask = 0
    for part in args[4].split(separator: ",") {
        switch part {
        case "shift": mask |= 1
        case "opt", "option": mask |= 2
        case "ctrl", "control": mask |= 4
        case "cmd", "command": break  // command is the AX baseline (mask 0)
        default: fail("error: unknown modifier '\(part)' (expected shift, opt, ctrl, cmd)")
        }
    }
    let match = menuBarItems().first {
        guard let cmdChar = attribute($0, "AXMenuItemCmdChar") as? String,
              cmdChar.caseInsensitiveCompare(char) == .orderedSame else { return false }
        let modifiers = (attribute($0, "AXMenuItemCmdModifiers") as? Int) ?? 0
        return modifiers == mask
    }
    guard let match else {
        fail("error: no menu item with keyboard equivalent \(args[4])+\(char)")
    }
    pressMenuItem(match, described: "\(args[4])+\(char)")

case "id":
    // Press by AXIdentifier — language-independent, for system chrome
    // with stable ids (the Open panel's OKButton/CancelButton; plain
    // Return never reaches the panel's bridged content, and its
    // window exposes no AXDefaultButton).
    let wanted = args.count > 3 ? args[3] : ""
    guard !wanted.isEmpty else { fail("usage: swift ax.swift <pid> id <identifier>") }
    guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else {
        fail("error: no windows for pid \(pid)")
    }
    var queue = windows
    var visited = 0
    var found: AXUIElement?
    while !queue.isEmpty, visited < 20_000, found == nil {
        let element = queue.removeFirst()
        visited += 1
        if identifier(element) == wanted, actions(element).contains(kAXPressAction) {
            found = element
        }
        queue.append(contentsOf: children(element))
    }
    guard let found else {
        fail("error: no pressable element with identifier '\(wanted)' (searched \(visited))")
    }
    let foundTitle = title(found)
    press(found)
    print("pressed: id=\(wanted) \"\(foundTitle)\"")

case "menulist":
    for item in menuBarItems() {
        let cmdChar = (attribute(item, "AXMenuItemCmdChar") as? String) ?? ""
        let modifiers = (attribute(item, "AXMenuItemCmdModifiers") as? Int) ?? 0
        let key = cmdChar.isEmpty ? "" : "  [\(modifiers)+\(cmdChar)]"
        print("\"\(title(item))\"\(key)")
    }

case "sidebar-state":
    // The sidebar is the only native list in the main window — content
    // is an AXWebArea, whose descendants (which can contain tables of
    // their own) are skipped. Scenes run this before Settings opens,
    // so every window is fair game.
    guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else {
        fail("error: no windows for pid \(pid)")
    }
    var queue = windows
    var visited = 0
    var found = false
    while !queue.isEmpty, visited < 20_000, !found {
        let element = queue.removeFirst()
        visited += 1
        let elementRole = role(element)
        if elementRole == "AXWebArea" { continue }
        if ["AXOutline", "AXList", "AXTable"].contains(elementRole) { found = true }
        queue.append(contentsOf: children(element))
    }
    print(found ? "visible" : "hidden")

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
            let id = identifier(element)
            print("\(role(element)) \"\(label(element))\" \(bounds)\(id.isEmpty ? "" : " id=\(id)")")
        }
        if depth < maxDepth {
            queue.append(contentsOf: children(element).map { ($0, depth + 1) })
        }
    }

default:
    fail("error: unknown command '\(args[2])' (expected menu, menuitem, menukey, press, sidebar-state, or list)")
}
