#if os(macOS)
import Foundation
import Testing
@testable import SwiftTerm

/// The primary side of a pseudo terminal must not leak into processes started later.
final class PtyCloseOnExecTests {
    private func spawn(_ args: [String]) -> (pid: pid_t, fd: Int32)? {
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard let r = PseudoTerminalHelpers.fork(andExec: args[0], args: args, env: ["PATH=/bin:/usr/bin"], desiredWindowSize: &size) else { return nil }
        return (r.pid, r.masterFd)
    }

    private func readAll(_ fd: Int32, timeout: TimeInterval = 5) -> String {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 100) > 0 else { continue }
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(decoding: out, as: UTF8.self)
    }

    @Test func primarySideIsCloseOnExec() throws {
        let child = try #require(spawn(["/bin/sleep", "5"]))
        defer { kill(child.pid, SIGKILL); waitpid(child.pid, nil, 0); close(child.fd) }
        let flags = fcntl(child.fd, F_GETFD)
        #expect(flags >= 0)
        #expect(flags & FD_CLOEXEC != 0)
    }

    @Test func laterChildDoesNotInheritEarlierPrimarySide() throws {
        let first = try #require(spawn(["/bin/sleep", "5"]))
        defer { kill(first.pid, SIGKILL); waitpid(first.pid, nil, 0); close(first.fd) }
        // The second child checks whether a descriptor with the number of the first
        // primary side is open, without opening anything itself (a redirection to an
        // unopened descriptor fails).
        let fd = first.fd
        let script = "if { true >&\(fd); } 2>/dev/null; then echo GEERBT; else echo FREI; fi"
        let second = try #require(spawn(["/bin/sh", "-c", script]))
        defer { kill(second.pid, SIGKILL); waitpid(second.pid, nil, 0); close(second.fd) }
        let answer = readAll(second.fd)
        #expect(answer.contains("FREI"), "zweites Kind erbt den Master des ersten Terminals (fd \(fd)): \(answer)")
    }
}
#endif
