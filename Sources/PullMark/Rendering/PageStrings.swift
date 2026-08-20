import Foundation

/// The rendered page's UI strings (spec: app-i18n). app.js copy is
/// unreachable by .strings lookup, so every key rides the render
/// payload, resolved here via Bundle.main. Keys are the English
/// strings; templated keys use {name} placeholders substituted by
/// app.js's pmFormat. scripts/check-strings.py verifies this table
/// covers every pmString/pmFormat key in app.js.
enum PageStrings {
    static let table: [String: String] = {
        var strings: [String: String] = [:]
        for key in keys {
            strings[key] = NSLocalizedString(key, comment: "rendered page")
        }
        return strings
    }()

    static let keys: [String] = [
        " · was {r}",
        "(empty)",
        "Add a margin note",
        "Add a suggestion",
        "Add reaction",
        "Add single comment",
        "Cancel",
        "Click the gutter for history",
        "Comment",
        "Comment actions",
        "Comment on line {n}",
        "Comment on lines {a}–{b}",
        "Comment on new line {n}",
        "Comment on new line {n} — shift-click extends the range",
        "Comment on new lines {a}–{b}",
        "Comment on old line {n} — shift-click extends the range",
        "Comment on old lines {a}–{b}",
        "Comment on the pull request conversation",
        "Conversation",
        "Copy full SHA",
        "Couldn't load this image from GitHub · ",
        "Delete",
        "Edit",
        "File comments",
        "Front matter",
        "Hide {n} resolved conversation",
        "Hide {n} resolved conversations",
        "Insert a ```suggestion block pre-filled with the current lines",
        "LEFT",
        "Leave a comment",
        "Line {n}",
        "Lines {a}–{b}",
        "Moved from line {n} — content unchanged",
        "No headings",
        "Not synced",
        "Old line {n}",
        "Old lines {a}–{b}",
        "Open on GitHub",
        "Open this conversation on GitHub — PullMark doesn't render this file",
        "Open {path} and jump to this conversation",
        "Outdated review comments",
        "Pending",
        "Pending comment — click to expand",
        "Pending comments — click to expand",
        "Post to the PR conversation right away — not part of a review (⌘↩)",
        "Reply",
        "Reply to this thread (⌘↩)",
        "Review discussion",
        "Save",
        "Save your edit (⌘↩)",
        "Show on GitHub",
        "Show {n} resolved conversation",
        "Show {n} resolved conversations",
        "Suggested change",
        "Suggestions can only target new-file lines — GitHub applies them in place of the commented lines.",
        "The conversation could not be loaded — retrying.",
        "The targeted lines aren't available to suggest an edit to.",
        "This block isn't part of the pull request's diff — GitHub can only attach comments to changed lines.",
        "This file is empty on both sides of the diff.",
        "View commit on GitHub",
        "View in File",
        "Write a reply",
        "Write at the end of the document",
        "all conversations resolved",
        "bot",
        "copied",
        "moved",
        "whole document",
        "{n} unresolved conversation",
        "{n} unresolved conversations",
        " · edited",
        "· asks where to open",
        "· opens in PullMark",
        "· opens in browser",
    ]
}
