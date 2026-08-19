import Foundation
import Testing
@testable import PullMark

/// The first-use intro's seen-state (spec: margin-notes-graduation):
/// alpha-era users who made an explicit enabled choice skip the intro;
/// fresh installs meet it on their first write action.
@Suite struct MarginNotesIntroTests {
    private func scratchDefaults(_ name: String) throws -> (UserDefaults, () -> Void) {
        let suiteName = "app.pullmark.tests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func freshInstallStaysUnseen() throws {
        let (defaults, cleanup) = try scratchDefaults("intro-fresh")
        defer { cleanup() }
        MarginNotesIntro.migrateAtLaunch(defaults: defaults)
        #expect(defaults.object(forKey: DefaultsKeys.marginNotesIntroSeen) == nil)
        #expect(!MarginNotesIntro.seen(defaults: defaults))
    }

    @Test func alphaEraEnabledSeedsSeen() throws {
        let (defaults, cleanup) = try scratchDefaults("intro-enabled")
        defer { cleanup() }
        defaults.set(true, forKey: DefaultsKeys.marginNotesEnabled)
        MarginNotesIntro.migrateAtLaunch(defaults: defaults)
        #expect(MarginNotesIntro.seen(defaults: defaults))
    }

    /// An explicit opt-out is just as informed a choice as an opt-in —
    /// flipping the toggle back on later must not pop the intro.
    @Test func alphaEraDisabledSeedsSeen() throws {
        let (defaults, cleanup) = try scratchDefaults("intro-disabled")
        defer { cleanup() }
        defaults.set(false, forKey: DefaultsKeys.marginNotesEnabled)
        MarginNotesIntro.migrateAtLaunch(defaults: defaults)
        #expect(MarginNotesIntro.seen(defaults: defaults))
        // The migration must not touch the choice itself.
        #expect(defaults.bool(forKey: DefaultsKeys.marginNotesEnabled) == false)
    }

    /// Whatever seen-state exists survives relaunches — the migration
    /// never overwrites, even the pathological explicit-false case.
    @Test func existingSeenValueIsNeverOverwritten() throws {
        let (defaults, cleanup) = try scratchDefaults("intro-kept")
        defer { cleanup() }
        defaults.set(false, forKey: DefaultsKeys.marginNotesIntroSeen)
        defaults.set(true, forKey: DefaultsKeys.marginNotesEnabled)
        MarginNotesIntro.migrateAtLaunch(defaults: defaults)
        #expect(defaults.bool(forKey: DefaultsKeys.marginNotesIntroSeen) == false)
    }

    @Test func markSeenPersists() throws {
        let (defaults, cleanup) = try scratchDefaults("intro-mark")
        defer { cleanup() }
        MarginNotesIntro.markSeen(defaults: defaults)
        #expect(MarginNotesIntro.seen(defaults: defaults))
        // Idempotent on a second launch's migration.
        MarginNotesIntro.migrateAtLaunch(defaults: defaults)
        #expect(MarginNotesIntro.seen(defaults: defaults))
    }
}
