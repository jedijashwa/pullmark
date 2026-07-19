import Foundation

/// Detection logic behind the DMG install greeter: identifies mounted
/// PullMark disk images and decides which offer (if any) launch should make.
/// macOS itself never offers to move an app out of its disk image or to
/// trash the image afterwards — apps that do this ship the behavior
/// themselves, and so does PullMark. Pure so it can be unit-tested; the
/// `hdiutil` call and the alerts live in `DMGGreeter`.
enum DiskImages {
    struct MountedImage: Equatable {
        /// Backing image file, e.g. ~/Downloads/PullMark-0.6.1.dmg.
        let imagePath: String
        /// Mount points, e.g. ["/Volumes/PullMark"].
        let mountPoints: [String]
    }

    enum LaunchOffer: Equatable {
        /// Running out of the mounted image (directly or app-translocated):
        /// offer to copy into /Applications and relaunch from there.
        case moveToApplications(MountedImage)
        /// Properly installed, but the release image is still mounted:
        /// offer to eject it and move the .dmg file to the Trash.
        case cleanup(MountedImage)
        case none
    }

    /// Parses `hdiutil info -plist` output into mounted images.
    static func parse(hdiutilInfo data: Data) -> [MountedImage] {
        guard let root = try? PropertyListSerialization
                .propertyList(from: data, format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return [] }
        return images.compactMap { image in
            guard let path = image["image-path"] as? String else { return nil }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            let mounts = entities.compactMap { $0["mount-point"] as? String }
            return mounts.isEmpty ? nil : MountedImage(imagePath: path, mountPoints: mounts)
        }
    }

    /// A PullMark release image: `PullMark-<version>.dmg` mounted at
    /// /Volumes/PullMark (Finder may suffix duplicates, e.g. "PullMark 1").
    static func isPullMarkImage(_ image: MountedImage) -> Bool {
        let file = (image.imagePath as NSString).lastPathComponent.lowercased()
        guard file.hasPrefix("pullmark"), file.hasSuffix(".dmg") else { return false }
        return image.mountPoints.contains {
            ($0 as NSString).lastPathComponent.hasPrefix("PullMark")
        }
    }

    /// Decides the launch offer. `bundlePath` must be a real .app bundle —
    /// `swift run` and test hosts never trigger the greeter, so a mounted
    /// image left over from a release build can't nag during development.
    static func offer(bundlePath: String, images: [MountedImage]) -> LaunchOffer {
        guard bundlePath.hasSuffix(".app"),
              let image = images.first(where: isPullMarkImage) else { return .none }
        let onImage = image.mountPoints.contains { bundlePath.hasPrefix($0 + "/") }
        // Gatekeeper app-translocation runs quarantined DMG apps from a
        // randomized read-only mirror, hiding the real volume path.
        let translocated = bundlePath.contains("/AppTranslocation/")
        if onImage || translocated { return .moveToApplications(image) }
        return .cleanup(image)
    }
}
