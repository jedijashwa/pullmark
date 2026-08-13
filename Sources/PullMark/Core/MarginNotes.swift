import Foundation

/// A margin note: an HTML comment of the shape
///
///     <!-- note @author: body -->
///     <!-- note @author (attrs):
///     multi-line markdown body
///     -->
///
/// parsed with its 1-based inclusive source line range. The format is
/// documented publicly (docs/beta/margin-notes) — agents read and write
/// these by hand, so the grammar here is the single Swift authority and
/// must stay in lockstep with the docs and with app.js's marker match.
struct MarginNote: Equatable {
    let author: String
    /// The reserved `(…)` slot between the author and the colon — parsed
    /// and preserved through edits, never interpreted (v1 writes none).
    let attributes: String?
    /// Unescaped Markdown body (`--\>` decoded back to `-->`).
    let body: String
    /// Leading spaces of the opening line (0–3). A note living inside a
    /// list item is indented to the item's content; edits must rewrite
    /// it at the same depth or the item spits it out.
    let indent: String
    let startLine: Int
    let endLine: Int
    /// Only front matter or other notes precede it: rendered as the
    /// document-level banner instead of under an anchor block.
    let isFileLevel: Bool
}

/// The web layer's view of a note: `index` is the note's ordinal in the
/// document, which the page pairs with the nth matching DOM comment node
/// and echoes back on edit/delete.
struct MarginNotePayload: Encodable, Equatable {
    let index: Int
    let author: String
    let body: String
    let fileLevel: Bool

    static func payloads(from notes: [MarginNote]) -> [MarginNotePayload] {
        notes.enumerated().map {
            MarginNotePayload(index: $0.offset, author: $0.element.author,
                              body: $0.element.body,
                              fileLevel: $0.element.isFileLevel)
        }
    }
}

enum MarginNotes {
    /// Paste-into-CLAUDE.md/AGENTS.md instructions — the Settings copy
    /// button and pullmark.app/docs/experimental/margin-notes ship the
    /// same text.
    static let agentInstructions = """
    ## Margin notes

    Markdown files may contain review notes as HTML comments:
    `<!-- note @name: comment -->` (possibly multi-line, closing
    with `-->` on its own line). Each note sits directly after the
    passage it's about; a note above the first heading is about the
    whole document. `--\\>` inside a note means a literal `-->`.

    When asked to address notes: work through each one, apply or
    answer it, and DELETE the note (with its surrounding blank line)
    once addressed. To reply or ask instead, leave your own note in
    the same format below the original, signed with your own @name.
    Don't add notes to code examples inside fenced blocks.

    A note about one list item sits inside that item — directly after
    the item's last line, indented to the item's content, with no
    blank lines around it. Keep (or delete) the whole indented
    comment; its indentation is what ties it to the item.
    """

    /// Opening-line shape: up to 3 leading spaces (4 would be a code
    /// block), `<!--`, the `note` keyword, `@`, then everything up to the
    /// first colon as author (+ optional trailing parenthesized attrs).
    private static let openPattern = #"^ {0,3}<!--\s*note\s+@([^:\n]+):(.*)$"#

    // MARK: Parsing

    /// All margin notes in `source`, in document order. Fenced code blocks
    /// are skipped (a note pasted into an example must stay an example),
    /// as is YAML front matter.
    static func parse(_ source: String) -> [MarginNote] {
        // CRLF sources parse identically to LF ones (line numbers are \n
        // splits either way; the stray \r would otherwise end up in
        // bodies and break the round-trip guard).
        let lines = source.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        let fmEnd = MarkdownBlocks.frontMatterEndLine(lines) ?? 0
        var notes: [(author: String, attrs: String?, body: String,
                     indent: String, start: Int, end: Int)] = []
        var fenceMarker: String?
        var i = fmEnd
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let marker = fenceMarker {
                if trimmed.hasPrefix(marker) { fenceMarker = nil }
                i += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fenceMarker = String(trimmed.prefix(3))
                i += 1
                continue
            }
            guard let match = line.range(of: openPattern, options: .regularExpression) else {
                i += 1
                continue
            }
            _ = match
            let indent = String(line.prefix(while: { $0 == " " }))
            let (header, rest) = headerParts(of: line)
            let (author, attrs) = splitAuthor(header)
            guard !author.isEmpty else { i += 1; continue }
            if let close = rest.range(of: "-->") {
                // Single-line form.
                let body = String(rest[..<close.lowerBound])
                notes.append((author, attrs, unescape(body.trimmingCharacters(in: .whitespaces)),
                              indent, i + 1, i + 1))
                i += 1
                continue
            }
            // Block form: body runs to the first line containing `-->`.
            // An indented (in-item) note writes its indent on every line;
            // dedenting here keeps bodies round-trip-identical to their
            // between-blocks siblings.
            func dedent(_ text: String) -> String {
                var t = Substring(text)
                var strip = indent.count
                while strip > 0, t.first == " " { t = t.dropFirst(); strip -= 1 }
                return String(t)
            }
            var bodyLines: [String] = []
            if !rest.trimmingCharacters(in: .whitespaces).isEmpty { bodyLines.append(rest) }
            var j = i + 1
            var closed = false
            while j < lines.count {
                if let close = lines[j].range(of: "-->") {
                    let head = dedent(String(lines[j][..<close.lowerBound]))
                    if !head.trimmingCharacters(in: .whitespaces).isEmpty { bodyLines.append(head) }
                    closed = true
                    break
                }
                bodyLines.append(dedent(lines[j]))
                j += 1
            }
            guard closed else { break }  // unterminated: not a note
            while bodyLines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                bodyLines.removeFirst()
            }
            while bodyLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                bodyLines.removeLast()
            }
            notes.append((author, attrs, unescape(bodyLines.joined(separator: "\n")),
                          indent, i + 1, j + 1))
            i = j + 1
        }

        // File-level = nothing but front matter, blanks, and other notes
        // above it.
        let ranges = notes.map { $0.start...$0.end }
        var firstContentLine = Int.max
        for (index, line) in lines.enumerated() {
            let number = index + 1
            if number <= fmEnd { continue }
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if ranges.contains(where: { $0.contains(number) }) { continue }
            firstContentLine = number
            break
        }
        return notes.map {
            MarginNote(author: $0.author, attributes: $0.attrs, body: $0.body,
                       indent: $0.indent, startLine: $0.start, endLine: $0.end,
                       isFileLevel: $0.end < firstContentLine)
        }
    }

    static func count(in source: String) -> Int {
        parse(source).count
    }

    // MARK: Writing

    /// The canonical serialized form: single line when the body fits on
    /// one, block form otherwise. `-->` in the body is escaped as `--\>`
    /// so it can never terminate the comment early. `indent` (an
    /// in-item note's item-content indent) prefixes every non-empty
    /// line; parse strips it back off block-form bodies.
    static func noteText(author: String, attributes: String? = nil, body: String,
                         indent: String = "") -> String {
        let escaped = escape(body)
        let attrs = attributes.map { " (\($0))" } ?? ""
        if !escaped.contains("\n") {
            return "\(indent)<!-- note @\(author)\(attrs): \(escaped) -->"
        }
        let block = "<!-- note @\(author)\(attrs):\n\(escaped)\n-->"
        return block.components(separatedBy: "\n")
            .map { $0.isEmpty ? $0 : indent + $0 }
            .joined(separator: "\n")
    }

    /// Inserts a note after 1-based line `afterLine` (0 = top of file;
    /// callers pass the front matter's end line to keep metadata first),
    /// separated from both neighbors by blank lines.
    ///
    /// `itemIndent` switches to the in-item form: the note is indented
    /// to a list item's content and packed tight against its neighbors —
    /// a blank line would flip a tight list loose, and an unindented
    /// comment would split the list in two.
    static func inserting(author: String, body: String, afterLine: Int,
                          itemIndent: String? = nil, in source: String) -> String {
        // The grammar tolerates at most 3 leading spaces (4 reads as an
        // indented code block); an invalid indent from the bridge must
        // degrade to a normal between-blocks note, never to a note the
        // parser can no longer see.
        let itemIndent = itemIndent.flatMap { indent in
            indent.count <= 3 && !indent.isEmpty
                && indent.allSatisfy { $0 == " " } ? indent : nil
        }
        var lines = source.components(separatedBy: "\n")
        let at = min(max(afterLine, 0), lines.count)
        var insert: [String] = []
        let text = noteText(author: author, body: body, indent: itemIndent ?? "")
        if itemIndent == nil {
            if at > 0, !(lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty) {
                insert.append("")
            }
            insert += text.components(separatedBy: "\n")
            if at < lines.count, !(lines[at].trimmingCharacters(in: .whitespaces).isEmpty) {
                insert.append("")
            }
        } else {
            insert = text.components(separatedBy: "\n")
        }
        lines.insert(contentsOf: insert, at: at)
        return lines.joined(separator: "\n")
    }

    /// Rewrites a note's body in place (author and attrs preserved).
    /// Returns nil when the note's lines no longer hold that note — the
    /// file changed underneath, same contract as block edits.
    static func replacingBody(of note: MarginNote, with body: String,
                              in source: String) -> String? {
        guard let lines = verifiedLines(of: note, in: source) else { return nil }
        var all = lines.all
        all.replaceSubrange(lines.range,
                            with: noteText(author: note.author,
                                           attributes: note.attributes,
                                           body: body,
                                           indent: note.indent).components(separatedBy: "\n"))
        return all.joined(separator: "\n")
    }

    /// Removes a note, tidying the blank line that separated it from its
    /// neighbor so no double gap is left behind. Nil when the note's
    /// lines no longer hold it.
    static func removing(_ note: MarginNote, from source: String) -> String? {
        guard let lines = verifiedLines(of: note, in: source) else { return nil }
        var all = lines.all
        all.removeSubrange(lines.range)
        let at = lines.range.lowerBound
        let blankAt = { (i: Int) in
            all.indices.contains(i)
                && all[i].trimmingCharacters(in: .whitespaces).isEmpty
        }
        if blankAt(at), at == 0 || blankAt(at - 1) {
            all.remove(at: at)
        }
        return all.joined(separator: "\n")
    }

    // MARK: Escaping

    /// The one reserved sequence: a literal `-->` in a body is written as
    /// `--\>` (nothing else is ever escaped — bodies are plain Markdown).
    static func escape(_ body: String) -> String {
        body.replacingOccurrences(of: "-->", with: "--\\>")
    }

    static func unescape(_ body: String) -> String {
        body.replacingOccurrences(of: "--\\>", with: "-->")
    }

    // MARK: Helpers

    /// (author-and-attrs text before the first colon, rest of the line).
    private static func headerParts(of line: String) -> (String, String) {
        guard let at = line.range(of: "@"),
              let colon = line.range(of: ":", range: at.upperBound..<line.endIndex) else {
            return ("", "")
        }
        return (String(line[at.upperBound..<colon.lowerBound]),
                String(line[colon.upperBound...]))
    }

    /// "Josh R (blocking)" → ("Josh R", "blocking").
    private static func splitAuthor(_ header: String) -> (String, String?) {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"),
              let open = trimmed.range(of: "(", options: .backwards) else {
            return (trimmed, nil)
        }
        let name = String(trimmed[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
        let attrs = String(trimmed[open.upperBound..<trimmed.index(before: trimmed.endIndex)])
        guard !name.isEmpty else { return (trimmed, nil) }
        return (name, attrs)
    }

    /// The source's lines, with the note's range verified to still parse
    /// as this exact note (optimistic-concurrency guard).
    private static func verifiedLines(of note: MarginNote, in source: String)
        -> (all: [String], range: Range<Int>)? {
        let current = parse(source)
        guard current.contains(where: {
            $0.startLine == note.startLine && $0.endLine == note.endLine
                && $0.author == note.author && $0.body == note.body
        }) else { return nil }
        let all = source.components(separatedBy: "\n")
        guard note.startLine >= 1, note.endLine <= all.count else { return nil }
        return (all, (note.startLine - 1)..<note.endLine)
    }
}
