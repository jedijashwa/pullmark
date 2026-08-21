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
            strings[key] = NSLocalizedString(
                key, value: disambiguated[key] ?? key, comment: "rendered page")
        }
        return strings
    }()

    /// Keys that aren't their own English text — the same English word
    /// translates differently by role (es: the Edit category is Edición,
    /// the Edit button Editar). value = the English display text, since
    /// there is no en.lproj to carry it.
    static let disambiguated: [String: String] = [
        "edit-action": "Edit",
    ]

    static let keys: [String] = [
        " · was {r}",
        "(empty)",
        "Add Note",
        "Add a margin note",
        "Add a suggestion",
        "Add reaction",
        "Add review comment",
        "Add single comment",
        "Add to your pending review — it posts when you submit the review (⌘↩)",
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
        "File comments",
        "Front matter",
        "Hide {n} resolved conversation",
        "Hide {n} resolved conversations",
        "Insert a ```suggestion block pre-filled with the current lines",
        "LEFT",
        "Leave a comment",
        "Leave a margin note",
        "Leave a note about the whole document",
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
        "Resolve",
        "Resolved",
        "Review discussion",
        "Save",
        "Save your edit (⌘↩)",
        "Show on GitHub",
        "Start a pending review with this comment (⌘↩)",
        "Start a review",
        "Show {n} resolved conversation",
        "Show {n} resolved conversations",
        "Suggested change",
        "Suggestions can only target new-file lines — GitHub applies them in place of the commented lines.",
        "The conversation could not be loaded — retrying.",
        "The targeted lines aren't available to suggest an edit to.",
        "This block isn't part of the pull request's diff — GitHub can only attach comments to changed lines.",
        "This file is empty on both sides of the diff.",
        "Unresolve",
        "View commit on GitHub",
        "View in File",
        "Write a reply",
        "Write at the end of the document",
        "all conversations resolved",
        "approved these changes",
        "bot",
        "copied",
        "dismissed their review",
        "edit-action",
        "moved",
        "requested changes",
        "reviewed",
        "whole document",
        "{n} comment",
        "{n} comment — click to expand",
        "{n} comments",
        "{n} comments — click to expand",
        "{n} review",
        "{n} reviews",
        "{n} unresolved conversation",
        "{n} unresolved conversations",
        " · edited",
        "· asks where to open",
        "· opens in PullMark",
        "· opens in browser",
    ]
}
