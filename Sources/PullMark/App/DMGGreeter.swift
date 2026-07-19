import AppKit

/// The install experience modern Mac apps ship themselves (macOS provides
/// neither prompt): launched from the disk image, offer to move PullMark
/// into /Applications and relaunch; launched installed with the release
/// image still mounted, offer to eject it and move the .dmg to the Trash.
@MainActor
enum DMGGreeter {
    static func runAtLaunch() {
        let bundlePath = Bundle.main.bundlePath
        Task.detached(priority: .utility) {
            let images = DiskImages.parse(hdiutilInfo: hdiutilInfo())
            await MainActor.run { handle(DiskImages.offer(bundlePath: bundlePath, images: images)) }
        }
    }

    private static func handle(_ offer: DiskImages.LaunchOffer) {
        switch offer {
        case .moveToApplications(let image):
            offerMove(image)
        case .cleanup(let image):
            // Ask once per image file; a declined offer never nags again.
            let declined = UserDefaults.standard.stringArray(forKey: DefaultsKeys.dmgCleanupDeclined) ?? []
            guard !declined.contains(image.imagePath) else { return }
            offerCleanup(image)
        case .none:
            break
        }
    }

    // MARK: Running from the image

    private static func offerMove(_ image: DiskImages.MountedImage) {
        let alert = NSAlert()
        alert.messageText = "Move PullMark to your Applications folder?"
        alert.informativeText = "PullMark is running from its disk image. "
            + "Moving it to Applications installs it properly and enables one-click updates."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let destination = "/Applications/PullMark.app"
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination) {
                try fm.removeItem(atPath: destination)
            }
            try fm.copyItem(atPath: Bundle.main.bundlePath, toPath: destination)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn't move PullMark"
            failure.informativeText = "Drag PullMark to Applications in the Finder instead. (\(error.localizedDescription))"
            failure.runModal()
            return
        }
        // The fresh copy takes over — it will find the image still mounted
        // and offer the Trash cleanup itself.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        relaunch.arguments = [destination]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    // MARK: Installed, image still mounted

    private static func offerCleanup(_ image: DiskImages.MountedImage) {
        let file = (image.imagePath as NSString).lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Remove the PullMark disk image?"
        alert.informativeText = "PullMark is installed — the disk image is no longer needed. "
            + "This ejects it and moves “\(file)” to the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep")
        guard alert.runModal() == .alertFirstButtonReturn else {
            var declined = UserDefaults.standard.stringArray(forKey: DefaultsKeys.dmgCleanupDeclined) ?? []
            declined.append(image.imagePath)
            UserDefaults.standard.set(declined, forKey: DefaultsKeys.dmgCleanupDeclined)
            return
        }
        let imagePath = image.imagePath
        let mountPoints = image.mountPoints
        Task.detached(priority: .utility) {
            for mount in mountPoints {
                let detach = Process()
                detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                detach.arguments = ["detach", mount]
                detach.standardOutput = FileHandle.nullDevice
                detach.standardError = FileHandle.nullDevice
                try? detach.run()
                detach.waitUntilExit()
            }
            await MainActor.run {
                guard FileManager.default.fileExists(atPath: imagePath) else { return }
                NSWorkspace.shared.recycle([URL(fileURLWithPath: imagePath)])
            }
        }
    }

    // MARK: hdiutil

    nonisolated private static func hdiutilInfo() -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Data()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}
