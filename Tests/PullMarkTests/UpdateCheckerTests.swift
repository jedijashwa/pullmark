import Foundation
import Testing
@testable import PullMark

@Suite struct SemVerTests {
    @Test func numericNotLexicographic() {
        #expect(SemVer.isNewer("1.10.0", than: "1.2.3"))
        #expect(!SemVer.isNewer("1.2.3", than: "1.10.0"))
        #expect(SemVer.compare("1.2.3", "1.10.0") == .orderedAscending)
    }

    @Test func vPrefixIgnored() {
        #expect(SemVer.isNewer("v0.2.0", than: "0.1.1"))
        #expect(SemVer.isNewer("0.2.0", than: "v0.1.1"))
        #expect(SemVer.compare("v1.0.0", "1.0.0") == .orderedSame)
    }

    @Test func equalVersions() {
        #expect(SemVer.compare("0.1.1", "0.1.1") == .orderedSame)
        #expect(!SemVer.isNewer("0.1.1", than: "0.1.1"))
    }

    @Test func missingComponentsCountAsZero() {
        #expect(SemVer.compare("1.2", "1.2.0") == .orderedSame)
        #expect(SemVer.isNewer("1.2.1", than: "1.2"))
    }

    @Test func prereleaseAndBuildSuffixesIgnored() {
        #expect(SemVer.compare("1.2.3-beta.1", "1.2.3") == .orderedSame)
        #expect(SemVer.isNewer("v1.3.0-rc.1+build.5", than: "1.2.9"))
        #expect(!SemVer.isNewer("1.2.3+42", than: "1.2.3"))
    }

    @Test func normalizedStripsPrefix() {
        #expect(SemVer.normalized("v0.2.0") == "0.2.0")
        #expect(SemVer.normalized(" 0.2.0 ") == "0.2.0")
    }
}

@Suite struct UpdateBannerTests {
    @MainActor private func makeChecker() -> UpdateChecker {
        let suite = "pm.tests.updatechecker"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // "0.0.0" keeps init's automatic check from touching the network.
        return UpdateChecker(currentVersion: "0.0.0", defaults: defaults)
    }

    private func release(_ tag: String, draft: Bool = false,
                         prerelease: Bool = false) -> UpdateRelease {
        UpdateRelease(tagName: tag, body: "notes for \(tag)",
                      htmlUrl: "https://example.com/\(tag)",
                      prerelease: prerelease, draft: draft)
    }

    @Test @MainActor func dismissalSuppressesAutomaticButNotManualChecks() {
        let checker = makeChecker()
        checker.apply(release("v0.4.0"), ignoringDismissal: false)
        #expect(checker.availableVersion == "0.4.0")
        #expect(checker.availableNotes == "notes for v0.4.0")

        checker.dismissAvailableUpdate()
        #expect(checker.availableVersion == nil)
        #expect(checker.availableNotes.isEmpty)
        #expect(checker.availableURL == nil)

        // Automatic re-check of the dismissed version stays quiet…
        checker.apply(release("v0.4.0"), ignoringDismissal: false)
        #expect(checker.availableVersion == nil)
        // …a manual check still surfaces it…
        checker.apply(release("v0.4.0"), ignoringDismissal: true)
        #expect(checker.availableVersion == "0.4.0")
        checker.dismissAvailableUpdate()
        // …and a newer version breaks through the dismissal.
        checker.apply(release("v0.5.0"), ignoringDismissal: false)
        #expect(checker.availableVersion == "0.5.0")
    }

    @Test @MainActor func draftsAndPrereleasesNeverRaiseTheBanner() {
        let checker = makeChecker()
        checker.apply(release("v0.4.0", draft: true), ignoringDismissal: false)
        checker.apply(release("v0.4.0", prerelease: true), ignoringDismissal: false)
        #expect(checker.availableVersion == nil)
    }
}

@Suite struct BrewUpdateTests {
    @Test func noBrewBinaryMeansDownloadWithoutRunningAnything() {
        var ran = false
        let method = BrewUpdate.detectMethod(
            fileExists: { _ in false },
            runner: { _, _ in ran = true; return true }
        )
        #expect(method == .download)
        #expect(!ran)
    }

    @Test func brewManagedInstallPrefersAppleSiliconBrew() {
        var probed: (String, [String])?
        let method = BrewUpdate.detectMethod(
            fileExists: { _ in true },  // both paths exist → first wins
            runner: { path, args in probed = (path, args); return true }
        )
        #expect(method == .brew(brewPath: "/opt/homebrew/bin/brew"))
        #expect(probed?.0 == "/opt/homebrew/bin/brew")
        #expect(probed?.1 == ["list", "--cask", "pullmark"])
    }

    @Test func fallsBackToIntelBrewPath() {
        let method = BrewUpdate.detectMethod(
            fileExists: { $0 == "/usr/local/bin/brew" },
            runner: { path, _ in path == "/usr/local/bin/brew" }
        )
        #expect(method == .brew(brewPath: "/usr/local/bin/brew"))
    }

    @Test func brewPresentButCaskNotInstalledMeansDownload() {
        let method = BrewUpdate.detectMethod(
            fileExists: { $0 == "/opt/homebrew/bin/brew" },
            runner: { _, _ in false }  // `brew list --cask pullmark` fails
        )
        #expect(method == .download)
    }

    @Test func commandConstruction() {
        #expect(BrewUpdate.command == "brew upgrade --cask pullmark")
        #expect(BrewUpdate.upgradeArguments == ["upgrade", "--cask", "pullmark"])
        #expect(BrewUpdate.listArguments == ["list", "--cask", "pullmark"])
    }

    @Test func relaunchTargetsTheRunningAppBundle() {
        #expect(BrewUpdate.relaunchAppPath(bundlePath: "/Applications/PullMark.app")
            == "/Applications/PullMark.app")
        #expect(BrewUpdate.relaunchAppPath(bundlePath: "/Users/x/Apps/PullMark.app")
            == "/Users/x/Apps/PullMark.app")
    }

    @Test func relaunchFallsBackToApplicationsForNonBundleBuilds() {
        // `swift run` executes straight from .build — no .app to reopen.
        #expect(BrewUpdate.relaunchAppPath(bundlePath: "/Users/x/pullmark/.build/debug")
            == "/Applications/PullMark.app")
    }

    @Test func relaunchCommandSleepsThenReopens() {
        #expect(BrewUpdate.relaunchShellCommand(appPath: "/Applications/PullMark.app")
            == "sleep 1; open -a \"/Applications/PullMark.app\"")
    }
}

@Suite struct UpdateReleaseTests {
    @Test func decodesReleaseJSON() throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "name": "PullMark 0.2.0",
          "html_url": "https://github.com/jedijashwa/pullmark/releases/tag/v0.2.0",
          "body": "## Highlights\\n\\n- In-app update checks\\n- What's New sheet",
          "draft": false,
          "prerelease": false,
          "assets": []
        }
        """
        let release = try JSONDecoder().decode(UpdateRelease.self, from: Data(json.utf8))
        #expect(release.tagName == "v0.2.0")
        #expect(release.htmlUrl == "https://github.com/jedijashwa/pullmark/releases/tag/v0.2.0")
        #expect(release.body?.contains("In-app update checks") == true)
        #expect(release.draft == false)
        #expect(release.prerelease == false)
    }

    @Test func decodesReleaseListWithMissingOptionalFields() throws {
        let json = """
        [
          {"tag_name": "v0.2.0", "html_url": "https://example.com/2", "body": "notes"},
          {"tag_name": "v0.1.1", "html_url": "https://example.com/1", "body": null}
        ]
        """
        let releases = try JSONDecoder().decode([UpdateRelease].self, from: Data(json.utf8))
        #expect(releases.count == 2)
        #expect(releases[1].body == nil)
        #expect(releases[0].prerelease == nil)
    }

    @Test func betweenSelectsRangeNewestFirst() {
        func release(_ tag: String, prerelease: Bool = false) -> UpdateRelease {
            UpdateRelease(tagName: tag, body: "notes for \(tag)",
                          htmlUrl: "https://example.com/\(tag)",
                          prerelease: prerelease, draft: false)
        }
        let releases = [
            release("v0.1.0"), release("v0.1.1"), release("v0.2.0"),
            release("v0.3.0"), release("v0.3.1-beta.1", prerelease: true),
        ]
        let picked = UpdateRelease.between(releases, after: "0.1.0", upTo: "0.3.0")
        #expect(picked.map(\.tagName) == ["v0.3.0", "v0.2.0", "v0.1.1"])
    }
}
