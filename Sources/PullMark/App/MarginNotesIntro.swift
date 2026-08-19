import Foundation

/// The one-time margin-notes intro (spec: margin-notes-graduation).
/// The feature is on by default; the first *write action* — hover
/// bubble, ⌥⌘M, menu item, or Edit/Delete on an existing bubble —
/// shows the intro sheet before anything happens. `seen` is the gate.
enum MarginNotesIntro {
    /// Alpha-era users made an explicit enabled choice with the full
    /// Settings explanation in front of them — seed the intro as seen
    /// so graduation never interrupts them. Idempotent; never
    /// overwrites an existing seen value (a fresh install has neither
    /// key and stays unseen).
    static func migrateAtLaunch(defaults: UserDefaults = .pullmark) {
        guard defaults.object(forKey: DefaultsKeys.marginNotesIntroSeen) == nil,
              defaults.object(forKey: DefaultsKeys.marginNotesEnabled) != nil
        else { return }
        defaults.set(true, forKey: DefaultsKeys.marginNotesIntroSeen)
    }

    /// Read directly (not @AppStorage): the document view consults this
    /// inside action handlers, and observing it would tie page re-renders
    /// to the seen-flip — the intro must never reload the page it's
    /// resuming an action on.
    static func seen(defaults: UserDefaults = .pullmark) -> Bool {
        defaults.bool(forKey: DefaultsKeys.marginNotesIntroSeen)
    }

    static func markSeen(defaults: UserDefaults = .pullmark) {
        defaults.set(true, forKey: DefaultsKeys.marginNotesIntroSeen)
    }
}
