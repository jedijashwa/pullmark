import Foundation

/// Watches a file for changes and re-arms itself after atomic saves
/// (rename/replace), which is how most editors write files.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var cancelled = false

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    deinit {
        cancelled = true
        source?.cancel()
    }

    /// Re-arm after the watched file disappears. A single fixed retry
    /// gave up forever when the file came back late (git checkout there
    /// and back); keep trying with backoff for as long as the view lives.
    private func rearm(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.cancelled else { return }
            self.start()
            if self.source != nil {
                self.onChange()
            } else {
                self.rearm(delay: min(delay * 2, 2.0))
            }
        }
    }

    private func start() {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let current = self.source else { return }
            if current.data.contains(.rename) || current.data.contains(.delete) {
                current.cancel()
                self.source = nil
                self.rearm(delay: 0.25)
            } else {
                self.onChange()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
    }
}
