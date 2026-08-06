import Foundation

/// The handle written into margin notes (`<!-- note @josh: … -->`):
/// the Settings override when set, else the signed-in GitHub login,
/// else the macOS account name. Colons can't appear in a name — the
/// first colon ends the header — so they're stripped defensively.
enum MarginNoteAuthor {
    static func current(viewerLogin: String?,
                        defaults: UserDefaults = .pullmark) -> String {
        let custom = defaults.string(forKey: DefaultsKeys.marginNoteAuthor)?
            .trimmingCharacters(in: .whitespaces)
        let name = custom?.isEmpty == false ? custom!
            : (viewerLogin?.isEmpty == false ? viewerLogin! : NSUserName())
        return name.replacingOccurrences(of: ":", with: "")
    }
}
