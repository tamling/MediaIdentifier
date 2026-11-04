import Foundation
// For open(2) and flock(2). Foundation does not re-export the C library on
// every platform, so it is imported explicitly.
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Keeps two Mediafins that share a configuration directory from doing the
/// same unattended run at the same time.
///
/// This became possible the moment the schedule was armed at startup rather
/// than only when the user pressed Apply: the native window and `mediafin`
/// in a terminal both read `~/.config/mediafin`, so both would find the same
/// run overdue, both would rename, and the loser's moves would fail against
/// files the winner had already moved. Within one process the serial queue
/// already prevents it; this is the part the queue cannot see.
///
/// `flock` and not a PID file: the kernel releases it when the process dies,
/// however it dies, so a crash during a run cannot leave the schedule
/// permanently blocked — which is exactly the failure a hand-rolled lock
/// file produces, and nobody notices until the nightly run has been silent
/// for a month.
public enum RunLock {

    /// Runs `work` while holding an exclusive lock on `url`.
    ///
    /// - Returns: false when another process holds the lock, in which case
    ///   `work` was not run at all.
    @discardableResult
    public static func withLock(at url: URL, _ work: () -> Void) -> Bool {
        // O_CLOEXEC matters: a run spawns rsync, ssh and yt-dlp, and without
        // it each child inherits this descriptor and goes on holding the
        // lock after Mediafin itself has let go of it.
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            // The lock could not even be created — a read-only configuration
            // directory, say. Running is the lesser evil: the alternative is
            // a schedule that never fires again and says nothing about why.
            work()
            return true
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        defer { flock(descriptor, LOCK_UN) }
        work()
        return true
    }
}
