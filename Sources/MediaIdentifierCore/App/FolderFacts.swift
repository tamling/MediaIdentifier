import Foundation

/// What a probe found out about one folder.
///
/// A struct rather than three calls into `FileManager` at the point of use,
/// because the point of use is the status panel and the status panel is drawn
/// by the window's own timer. `stat` on a dead CIFS or NFS mount blocks until
/// the kernel gives up — sixty seconds is the CIFS default, per call — and the
/// window froze in exactly the state where the settings that would fix the
/// path cannot be reached.
public struct FolderFacts: Sendable, Equatable {
    public var exists: Bool
    public var isDirectory: Bool
    public var isWritable: Bool
    /// The probe did not come back in time, so nothing above is known.
    ///
    /// Its own flag rather than `exists == false`, because "the drive is not
    /// mounted" and "the drive is mounted and not answering" need different
    /// sentences: the first is something the user can fix, the second is
    /// something they have to wait out or unmount.
    public var timedOut: Bool

    public init(exists: Bool = false, isDirectory: Bool = false,
                isWritable: Bool = false, timedOut: Bool = false) {
        self.exists = exists
        self.isDirectory = isDirectory
        self.isWritable = isWritable
        self.timedOut = timedOut
    }

    public static let unreachable = FolderFacts(timedOut: true)

    /// The real thing. Not used by the status panel directly — it goes
    /// through `FolderInspector`, which is what bounds the wait.
    public static func measured(_ path: String,
                                fileManager: FileManager = .default) -> FolderFacts {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
        guard exists else { return FolderFacts() }
        return FolderFacts(exists: true,
                           isDirectory: isDirectory.boolValue,
                           isWritable: fileManager.isWritableFile(atPath: path))
    }
}

/// Finds out about folders without ever making the caller wait for a mount.
///
/// Three rules, each of which cost a wrong first draft:
///
/// **One probe per path, not one per call.** A probe that is stuck is stuck
/// in `stat` and cannot be cancelled — the thread is in a syscall. If a dead
/// mount and a local disk were measured in the same work item, the dead one
/// would make the local one unknown too, and the panel would go red about a
/// folder that is perfectly fine.
///
/// **A path still out is unknown, not what it was last time.** Returning the
/// cached answer after a timeout reads as "green", which is the panel lying
/// about a folder that has just gone away — the one thing this panel exists
/// not to do.
///
/// **It heals itself.** When the mount comes back the stuck `stat` returns,
/// the work item fills the cache and clears the path, and the next call waits
/// for it again. At most one blocked thread per configured folder exists at
/// any moment, whatever happens.
public final class FolderInspector: @unchecked Sendable {

    /// Injectable so a test can block on demand. The production value reads
    /// the real filesystem.
    public typealias Probe = @Sendable (String) -> FolderFacts

    private let lock = NSLock()
    private var cache: [String: FolderFacts] = [:]
    /// Paths whose probe has been started and has not come back.
    private var inFlight: Set<String> = []

    private let deadline: TimeInterval
    private let probe: Probe
    /// Concurrent on purpose: see the first rule above.
    private let queue = DispatchQueue(label: "mediafin.folders", qos: .utility,
                                      attributes: .concurrent)

    public init(deadline: TimeInterval = 2, probe: Probe? = nil) {
        self.deadline = max(0.05, deadline)
        self.probe = probe ?? { FolderFacts.measured($0) }
    }

    /// The facts for `paths`, waiting at most `deadline` in all.
    ///
    /// Call this from a background queue, never from the thread that draws.
    public func facts(for paths: [String]) -> [String: FolderFacts] {
        let wanted = Array(Set(paths.filter { !$0.isEmpty }))
        guard !wanted.isEmpty else { return [:] }

        lock.lock()
        let toStart = wanted.filter { !inFlight.contains($0) }
        for path in toStart { inFlight.insert(path) }
        lock.unlock()

        let group = DispatchGroup()
        for path in toStart {
            group.enter()
            queue.async { [weak self] in
                defer { group.leave() }
                guard let self else { return }
                // Outside the lock: this is the part that blocks, and holding
                // the lock through it would block every reader as well.
                let facts = self.probe(path)
                self.lock.lock()
                self.cache[path] = facts
                self.inFlight.remove(path)
                self.lock.unlock()
            }
        }
        _ = group.wait(timeout: .now() + deadline)

        lock.lock(); defer { lock.unlock() }
        var out: [String: FolderFacts] = [:]
        for path in wanted {
            out[path] = inFlight.contains(path)
                ? .unreachable
                : (cache[path] ?? .unreachable)
        }
        return out
    }

    /// What is known, with no waiting and no probing. For tests and for a
    /// caller that only wants to know whether anything has been measured.
    /// What the cache holds for `path`, without starting a probe.
    ///
    /// Named *ForTesting because nothing in the program wants it: a reader
    /// asks `facts(for:)`, which starts a fresh probe when the answer is
    /// stale, and that is how a mount coming back is noticed at all. A test
    /// waiting for a late probe's answer to land has no other way to see it
    /// arrive, and polling `facts(for:)` would start the probe it is
    /// waiting for.
    public func cachedFactsForTesting(for path: String) -> FolderFacts? {
        lock.lock(); defer { lock.unlock() }
        return cache[path]
    }
}
