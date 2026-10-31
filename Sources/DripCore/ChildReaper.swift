#if !os(WASI)
import Foundation

/// Reaps a child nobody waits on. A drip that returns at once leaves such a child to launchd, but
/// `drip follow` runs for days and spawns one background drip per card; each that finished stayed
/// a zombie, one more of the user's process slots, until `follow` exited.
///
/// This waits for that one pid, not for any child, and does not ignore SIGCHLD: `Run` and
/// `TimedCommand` wait on their own children, and with SIGCHLD ignored their `waitpid` would fail
/// with ECHILD.
public enum ChildReaper {
    /// Waits for the child `pid` on a thread of its own, which ends once the child has exited and
    /// been reaped. A thread, not a dispatch worker: a child can run for as long as its card waits.
    public static func reap(_ pid: pid_t) {
        let thread = Thread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        }
        thread.name = "drip-reap-\(pid)"
        thread.stackSize = 64 * 1024
        thread.start()
    }
}
#endif
