import Testing
import Foundation
@testable import PullMark

@Suite("Disk image detection")
struct DiskImagesTests {
    /// Minimal `hdiutil info -plist` shape: two images, one PullMark release
    /// image mounted at /Volumes/PullMark, one unrelated.
    private func plist(_ body: String) -> Data {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>images</key><array>\(body)</array>
        </dict></plist>
        """.data(using: .utf8)!
    }

    private func imageDict(path: String, mounts: [String]) -> String {
        let entities = mounts.map {
            "<dict><key>mount-point</key><string>\($0)</string></dict>"
        }.joined()
        return """
        <dict>
        <key>image-path</key><string>\(path)</string>
        <key>system-entities</key><array>\(entities)
        <dict><key>content-hint</key><string>GUID_partition_scheme</string></dict>
        </array>
        </dict>
        """
    }

    private var pullMarkImage: DiskImages.MountedImage {
        DiskImages.MountedImage(imagePath: "/Users/me/Downloads/PullMark-0.6.1.dmg",
                                mountPoints: ["/Volumes/PullMark"])
    }

    @Test func parsesImagesAndMountPoints() {
        let data = plist(
            imageDict(path: "/Users/me/Downloads/PullMark-0.6.1.dmg", mounts: ["/Volumes/PullMark"])
            + imageDict(path: "/Users/me/other.dmg", mounts: ["/Volumes/Other"])
        )
        let images = DiskImages.parse(hdiutilInfo: data)
        #expect(images == [
            DiskImages.MountedImage(imagePath: "/Users/me/Downloads/PullMark-0.6.1.dmg",
                                    mountPoints: ["/Volumes/PullMark"]),
            DiskImages.MountedImage(imagePath: "/Users/me/other.dmg",
                                    mountPoints: ["/Volumes/Other"]),
        ])
    }

    @Test func skipsUnmountedAndMalformedEntries() {
        let data = plist(
            imageDict(path: "/Users/me/Downloads/PullMark-0.6.1.dmg", mounts: [])
            + "<dict><key>irrelevant</key><string>x</string></dict>"
        )
        #expect(DiskImages.parse(hdiutilInfo: data).isEmpty)
        #expect(DiskImages.parse(hdiutilInfo: Data()).isEmpty)
    }

    @Test func recognizesOnlyPullMarkReleaseImages() {
        #expect(DiskImages.isPullMarkImage(pullMarkImage))
        // Finder duplicate-volume suffix still counts.
        #expect(DiskImages.isPullMarkImage(.init(imagePath: "/x/pullmark-0.5.0.dmg",
                                                 mountPoints: ["/Volumes/PullMark 1"])))
        // Wrong file name or wrong volume: not ours.
        #expect(!DiskImages.isPullMarkImage(.init(imagePath: "/x/Other-1.0.dmg",
                                                  mountPoints: ["/Volumes/PullMark"])))
        #expect(!DiskImages.isPullMarkImage(.init(imagePath: "/x/PullMark-0.6.1.dmg",
                                                  mountPoints: ["/Volumes/SomethingElse"])))
    }

    @Test func offersMoveWhenRunningFromTheImage() {
        let offer = DiskImages.offer(bundlePath: "/Volumes/PullMark/PullMark.app",
                                     images: [pullMarkImage])
        #expect(offer == .moveToApplications(pullMarkImage))
    }

    @Test func offersMoveWhenTranslocated() {
        let offer = DiskImages.offer(
            bundlePath: "/private/var/folders/ab/T/AppTranslocation/9A1B/d/PullMark.app",
            images: [pullMarkImage])
        #expect(offer == .moveToApplications(pullMarkImage))
    }

    @Test func offersCleanupWhenInstalledAndImageStillMounted() {
        let offer = DiskImages.offer(bundlePath: "/Applications/PullMark.app",
                                     images: [pullMarkImage])
        #expect(offer == .cleanup(pullMarkImage))
    }

    @Test func noOfferWithoutAPullMarkImage() {
        let other = DiskImages.MountedImage(imagePath: "/x/Other.dmg",
                                            mountPoints: ["/Volumes/Other"])
        #expect(DiskImages.offer(bundlePath: "/Applications/PullMark.app",
                                 images: [other]) == .none)
        #expect(DiskImages.offer(bundlePath: "/Applications/PullMark.app",
                                 images: []) == .none)
    }

    @Test func devBuildsNeverTriggerTheGreeter() {
        // `swift run` and the test host aren't .app bundles — a release
        // image left mounted by make-dmg.sh must not nag during development.
        let offer = DiskImages.offer(bundlePath: "/Users/me/code/pullmark/.build/debug",
                                     images: [pullMarkImage])
        #expect(offer == .none)
    }
}
