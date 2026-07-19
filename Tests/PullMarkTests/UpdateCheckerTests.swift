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

    @Test @MainActor func applyStoresTheZipAssetURLAndDismissClearsIt() {
        let checker = makeChecker()
        let withAsset = UpdateRelease(
            tagName: "v0.4.0", body: nil, htmlUrl: "https://example.com/r",
            prerelease: false, draft: false,
            assets: [UpdateAsset(name: "PullMark-0.4.0.zip",
                                 browserDownloadUrl: "https://example.com/a.zip")])
        checker.apply(withAsset, ignoringDismissal: true)
        #expect(checker.availableZipURL == "https://example.com/a.zip")
        checker.dismissAvailableUpdate()
        #expect(checker.availableZipURL == nil)
    }

    @Test @MainActor func draftsAndPrereleasesNeverRaiseTheBanner() {
        let checker = makeChecker()
        checker.apply(release("v0.4.0", draft: true), ignoringDismissal: false)
        checker.apply(release("v0.4.0", prerelease: true), ignoringDismissal: false)
        #expect(checker.availableVersion == nil)
    }
}

@Suite struct BrewUpdateTests {
    /// The canonical cask install target — the path brew manages.
    private let installedApp = "/Applications/PullMark.app"

    @Test func noBrewBinaryMeansSelfUpdateWithoutRunningAnything() {
        var ran = false
        let method = BrewUpdate.detectMethod(
            bundlePath: installedApp,
            fileExists: { _ in false },
            runner: { _, _ in ran = true; return true }
        )
        #expect(method == .selfUpdate)
        #expect(!ran)
    }

    @Test func brewManagedInstallPrefersAppleSiliconBrew() {
        var probed: (String, [String])?
        let method = BrewUpdate.detectMethod(
            bundlePath: installedApp,
            fileExists: { _ in true },  // both paths exist → first wins
            runner: { path, args in probed = (path, args); return true }
        )
        #expect(method == .brew(brewPath: "/opt/homebrew/bin/brew"))
        #expect(probed?.0 == "/opt/homebrew/bin/brew")
        #expect(probed?.1 == ["list", "--cask", "pullmark"])
    }

    @Test func fallsBackToIntelBrewPath() {
        let method = BrewUpdate.detectMethod(
            bundlePath: installedApp,
            fileExists: { $0 == "/usr/local/bin/brew" },
            runner: { path, _ in path == "/usr/local/bin/brew" }
        )
        #expect(method == .brew(brewPath: "/usr/local/bin/brew"))
    }

    @Test func brewPresentButCaskNotInstalledMeansSelfUpdate() {
        let method = BrewUpdate.detectMethod(
            bundlePath: installedApp,
            fileExists: { $0 == "/opt/homebrew/bin/brew" },
            runner: { _, _ in false }  // `brew list --cask pullmark` fails
        )
        #expect(method == .selfUpdate)
    }

    @Test func brewManagedCaskDoesNotClaimABundleRunningElsewhere() {
        // The cask may be installed on the machine, but the RUNNING copy is
        // some other bundle (e.g. /tmp, ~/Apps) — brew must not update it.
        var ran = false
        let method = BrewUpdate.detectMethod(
            bundlePath: "/tmp/PMTest/PullMark.app",
            fileExists: { _ in true },
            runner: { _, _ in ran = true; return true }
        )
        #expect(method == .selfUpdate)
        #expect(!ran)  // no point probing brew for a bundle it doesn't manage
    }

    @Test func caskroomBundleCountsAsBrewManaged() {
        let method = BrewUpdate.detectMethod(
            bundlePath: "/opt/homebrew/Caskroom/pullmark/0.4.0/PullMark.app",
            fileExists: { $0 == "/opt/homebrew/bin/brew" },
            runner: { _, _ in true }
        )
        #expect(method == .brew(brewPath: "/opt/homebrew/bin/brew"))
    }

    @Test func nonBundleDevBuildFallsBackToDownload() {
        // `swift run` executes from .build — there is no .app to swap.
        let method = BrewUpdate.detectMethod(
            bundlePath: "/Users/x/pullmark/.build/debug",
            fileExists: { _ in true },
            runner: { _, _ in true }
        )
        #expect(method == .download)
    }

    @Test func isBrewInstalledBundleMatchesTargetAndCaskroomOnly() {
        let brew = "/opt/homebrew/bin/brew"
        #expect(BrewUpdate.isBrewInstalledBundle(
            bundlePath: "/Applications/PullMark.app", brewPath: brew))
        #expect(BrewUpdate.isBrewInstalledBundle(
            bundlePath: "/opt/homebrew/Caskroom/pullmark/0.4.0/PullMark.app", brewPath: brew))
        #expect(BrewUpdate.isBrewInstalledBundle(
            bundlePath: "/usr/local/Caskroom/pullmark/0.4.0/PullMark.app",
            brewPath: "/usr/local/bin/brew"))
        #expect(!BrewUpdate.isBrewInstalledBundle(
            bundlePath: "/tmp/PMTest/PullMark.app", brewPath: brew))
        #expect(!BrewUpdate.isBrewInstalledBundle(
            bundlePath: "/Users/x/Apps/PullMark.app", brewPath: brew))
        #expect(!BrewUpdate.isBrewInstalledBundle(
            bundlePath: "/Applications/PullMark Helper.app", brewPath: brew))
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
        // Shape mirrors the GitHub REST releases API, including the asset
        // fields the self-updater needs (browser_download_url).
        let json = """
        {
          "tag_name": "v0.2.0",
          "name": "PullMark 0.2.0",
          "html_url": "https://github.com/jedijashwa/pullmark/releases/tag/v0.2.0",
          "body": "## Highlights\\n\\n- In-app update checks\\n- What's New sheet",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "PullMark-0.2.0.dmg",
              "content_type": "application/x-apple-diskimage",
              "size": 3141674,
              "browser_download_url": "https://github.com/jedijashwa/pullmark/releases/download/v0.2.0/PullMark-0.2.0.dmg"
            },
            {
              "name": "PullMark-0.2.0.zip",
              "content_type": "application/zip",
              "size": 3114855,
              "browser_download_url": "https://github.com/jedijashwa/pullmark/releases/download/v0.2.0/PullMark-0.2.0.zip"
            }
          ]
        }
        """
        let release = try JSONDecoder().decode(UpdateRelease.self, from: Data(json.utf8))
        #expect(release.tagName == "v0.2.0")
        #expect(release.htmlUrl == "https://github.com/jedijashwa/pullmark/releases/tag/v0.2.0")
        #expect(release.body?.contains("In-app update checks") == true)
        #expect(release.draft == false)
        #expect(release.prerelease == false)
        #expect(release.assets?.count == 2)
        #expect(release.assets?[1].name == "PullMark-0.2.0.zip")
        // zipAssetURL picks the .zip, not the .dmg listed first.
        #expect(release.zipAssetURL ==
            "https://github.com/jedijashwa/pullmark/releases/download/v0.2.0/PullMark-0.2.0.zip")
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
        #expect(releases[0].assets == nil)
        #expect(releases[0].zipAssetURL == nil)
    }

    @Test func zipAssetURLIsNilWithoutAZipAsset() {
        let dmgOnly = UpdateRelease(
            tagName: "v0.2.0", body: nil, htmlUrl: "https://example.com/2",
            prerelease: false, draft: false,
            assets: [UpdateAsset(name: "PullMark-0.2.0.dmg",
                                 browserDownloadUrl: "https://example.com/d.dmg")])
        #expect(dmgOnly.zipAssetURL == nil)
        let empty = UpdateRelease(tagName: "v0.2.0", body: nil,
                                  htmlUrl: "https://example.com/2",
                                  prerelease: false, draft: false, assets: [])
        #expect(empty.zipAssetURL == nil)
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
