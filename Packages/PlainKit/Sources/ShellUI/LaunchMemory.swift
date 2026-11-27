#if canImport(UIKit)
import BrowserCore
import Foundation
import PerfSignposts
import UIKit

/// What one window remembers for the next launch (docs/decisions.md, "Launch: the last tab
/// first"): a `LaunchHint` in user defaults (in memory by the time the scene connects, so the
/// first frame reads it without touching the disk) and a full-size picture of the page on screen,
/// a JPEG beside the tab thumbnails.
///
/// The picture is taken when the app resigns active, while the page is still in the window, and is
/// encoded and written off the main thread. At the next launch `LaunchPicture` decodes it off the
/// main thread as soon as the scene connects.
public final class LaunchMemory {
    private let defaults: UserDefaults
    /// This window's hint, when the scene knows its window. An empty value marks a window that
    /// showed no page when it last left: it opens to search, never to another window's page.
    private let windowKey: String?
    /// The hint any window left last. A scene the system made new (the app was swiped away in the
    /// switcher, or the scene's saved state did not land before the app ended) has no window id;
    /// the last hint is the best guess, and launch checks it against the tab the restored session
    /// actually selects (on iPhone, with one window, they are the same).
    private let lastKey: String
    public let windowID: UUID?
    private let directory: URL
    /// Bumped by every save and clear: a snapshot that comes back after a newer one, or after a
    /// clear, is dropped.
    private var generation = 0
    /// Picture writes and deletes, one after another in the order issued.
    private var fileWork: Task<Void, Never>?

    private static let keyPrefix = "plain.launch."

    /// - Parameters:
    ///   - directory: where the pictures live (an isolated test run passes its own folder).
    ///   - defaults: where the hints live: `TestIsolation.defaults`, so a test run never reads or
    ///     writes the owner's hint.
    ///   - windowID: the scene's window, if it has one; each window remembers its own page.
    public init(directory: URL, defaults: UserDefaults = TestIsolation.defaults, windowID: UUID?) {
        self.defaults = defaults
        self.directory = directory
        self.windowID = windowID
        windowKey = windowID.map { Self.keyPrefix + $0.uuidString }
        lastKey = Self.keyPrefix + "last"
    }

    /// The hint this window left last time; for a window that never left one, the hint any window
    /// left last.
    public var hint: LaunchHint? {
        if let windowKey, let data = defaults.data(forKey: windowKey) {
            return Self.decode(data)
        }
        return defaults.data(forKey: lastKey).flatMap(Self.decode)
    }

    private static func decode(_ data: Data) -> LaunchHint? {
        data.isEmpty ? nil : try? JSONDecoder().decode(LaunchHint.self, from: data)
    }

    /// Starts decoding `hint`'s picture off the main thread now.
    public func startDecodingPicture(for hint: LaunchHint) -> LaunchPicture {
        LaunchPicture(file: directory.appending(path: hint.picture))
    }

    /// Starts a save: the snapshot it waits for counts only if no save or clear came after it.
    func beginSave() -> Int {
        generation += 1
        return generation
    }

    /// Remembers `hint` and its page's picture. The picture is written first, under a new name, and
    /// the hint naming it is published only once that write succeeded, so a hint never points at
    /// another page's picture; older pictures of the window go after.
    func save(_ hint: LaunchHint, picture: UIImage, generation: Int) {
        guard generation == self.generation else { return }
        let window = hint.windowID
        let name = "\(window.uuidString)-\(UUID().uuidString).jpg"
        let url = directory.appending(path: name)
        let directory = directory
        enqueue { [weak self] in
            let written = await Self.writeJPEG(picture, to: url)
            guard let self, written, generation == self.generation else {
                await Self.delete(url)
                return
            }
            var hint = hint
            hint.picture = name
            self.publish(hint)
            await Self.deletePictures(of: window, in: directory, keeping: name)
        }
    }

    /// The window shows no page (or one Plain keeps no picture of): its next launch opens to
    /// search.
    func clear() {
        generation += 1
        if let windowKey { defaults.set(Data(), forKey: windowKey) }
        if let last = defaults.data(forKey: lastKey).flatMap(Self.decode), last.windowID == windowID || windowID == nil {
            defaults.removeObject(forKey: lastKey)
        }
        guard let windowID else { return }
        let directory = directory
        enqueue { await Self.deletePictures(of: windowID, in: directory, keeping: nil) }
    }

    /// `clear()`, unless a newer save or clear came after `generation` began.
    func clear(ifCurrent generation: Int) {
        guard generation == self.generation else { return }
        clear()
    }

    private func publish(_ hint: LaunchHint) {
        guard let data = try? JSONEncoder().encode(hint) else { return }
        if let windowKey { defaults.set(data, forKey: windowKey) }
        defaults.set(data, forKey: lastKey)
    }

    /// Runs file work after the work before it, so an older picture never lands last.
    private func enqueue(_ work: @escaping () async -> Void) {
        let previous = fileWork
        fileWork = Task {
            await previous?.value
            await work()
        }
    }

    /// Waits for pending picture writes (the app is going to the background).
    func waitForWrites() async {
        await fileWork?.value
    }

    /// Encodes and writes the picture off the main thread. False when it could not be written.
    @concurrent
    private nonisolated static func writeJPEG(_ image: UIImage, to url: URL) async -> Bool {
        let interval = Signposts.signposter.beginInterval(Signposts.launchPictureSave)
        defer { Signposts.signposter.endInterval(Signposts.launchPictureSave, interval) }
        guard let data = image.jpegData(compressionQuality: LaunchChoices.jpegQuality) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @concurrent
    private nonisolated static func delete(_ url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes `window`'s pictures except `keeping`.
    @concurrent
    private nonisolated static func deletePictures(of window: UUID, in directory: URL, keeping: String?) async {
        let prefix = window.uuidString + "-"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for file in files where file.hasPrefix(prefix) && file != keeping {
            try? FileManager.default.removeItem(at: directory.appending(path: file))
        }
    }
}

/// The last tab's picture, read and decoded off the main thread from the moment it is made. The
/// first frame takes it if it is ready, and otherwise waits for it at most
/// `FixedChoices.launchPictureWait`.
public nonisolated final class LaunchPicture: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var finished = false
    private var image: UIImage?

    init(file: URL) {
        let interval = Signposts.signposter.beginInterval(Signposts.launchPictureDecode)
        Task.detached(priority: .userInitiated) { [self] in
            // Decoded here, at the picture's own size (the page's points at 2x), so Core
            // Animation draws it without a decode on the main thread.
            let decoded = UIImage(contentsOfFile: file.path(percentEncoded: false))?.preparingForDisplay()
            lock.withLock {
                image = decoded
                finished = true
            }
            done.signal()
            Signposts.signposter.endInterval(Signposts.launchPictureDecode, interval, "\(decoded == nil ? "none" : "decoded")")
        }
    }

    /// The decoded picture, waiting up to `timeout` for the decode to finish. Nil when there is
    /// no picture or it is not ready in time.
    func take(waitingUpTo timeout: Duration) -> UIImage? {
        if let ready = lock.withLock({ finished ? image : nil }) { return ready }
        if lock.withLock({ finished }) { return nil }
        let signposter = Signposts.signposter
        let interval = signposter.beginInterval(Signposts.launchPictureWait)
        let nanoseconds = Int(timeout.components.seconds) * 1_000_000_000 + Int(timeout.components.attoseconds / 1_000_000_000)
        let result = done.wait(timeout: .now() + .nanoseconds(nanoseconds))
        if result == .success { done.signal() }
        signposter.endInterval(Signposts.launchPictureWait, interval, "\(result == .success ? "ready" : "timedOut")")
        return lock.withLock { image }
    }

    /// The picture once it is decoded, for a first frame that went without it.
    func whenReady() async -> UIImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                done.wait()
                done.signal()
                continuation.resume(returning: lock.withLock { image })
            }
        }
    }
}

/// Values for the launch picture, with their reasons. Its size is the bar swipe's full-screen
/// preview (`WebViewPool.snapshot(of:width:)`, 2 px per point): sharp at full width for the second
/// or so it shows, a third fewer pixels than a 3x screen to decode.
nonisolated enum LaunchChoices {
    /// The page has longer than usual to answer (`EngineChoices.webKitReplyTimeout` is 400 ms):
    /// the app is leaving, nothing waits on the picture, and the work runs in `BackgroundWork`. A
    /// busy page (or a loaded phone) still gets its picture.
    static let snapshotTimeout: Duration = .seconds(2)
    /// Invisible loss at this size for a picture that shows briefly; about 150 to 300 KB.
    static let jpegQuality: CGFloat = 0.75
}
#endif
