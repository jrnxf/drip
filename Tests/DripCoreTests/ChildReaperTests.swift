#if !os(WASI) // Spawns processes, which WebAssembly cannot.
import DripCore
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct ChildReaperTests {
    private func spawnExiting() -> pid_t {
        var pid = pid_t()
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("sh"), strdup("-c"), strdup("exit 0"), nil]
        defer { arguments.forEach { free($0) } }
        #expect(posix_spawn(&pid, "/bin/sh", nil, nil, &arguments, environ) == 0)
        return pid
    }

    /// Whether the process table still holds `pid`, a zombie included.
    private func exists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func settle(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }

    /// `drip follow` spawns a background drip for every card and never waits on it, so each that
    /// finished stayed a zombie until `follow` exited, and a heavy user's days of cards used up
    /// the user's process slots.
    @Test func aFinishedChildIsNotLeftAZombie() {
        // The control: an unreaped child that has exited is still in the process table, so the
        // check below can tell a zombie from a reaped child.
        let neglected = spawnExiting()
        usleep(300_000)
        #expect(exists(neglected))
        var status: Int32 = 0
        waitpid(neglected, &status, 0)

        let children = (0 ..< 20).map { _ in spawnExiting() }
        children.forEach(ChildReaper.reap)
        #expect(settle { children.allSatisfy { !exists($0) } }, "zombies: \(children.filter(exists))")
    }
}
#endif
