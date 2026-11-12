#if os(macOS)
import Foundation
import Testing
@testable import SwiftTerm

/// Handing a running child from one `LocalProcess` to another, as a terminal
/// host does before it restarts.
@MainActor
final class LocalProcessHandoverTests {
    final class Recorder: LocalProcessDelegate {
        var bytes: [UInt8] = []
        var exits: [Int32?] = []
        func processTerminated(_ source: LocalProcess, exitCode: Int32?) { exits.append(exitCode) }
        func dataReceived(slice: ArraySlice<UInt8>) { bytes.append(contentsOf: slice) }
        func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
        var text: String { String(decoding: bytes, as: UTF8.self) }
    }

    private let dir: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lp-handover-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit { try? FileManager.default.removeItem(at: dir) }

    private func wait(_ timeout: TimeInterval = 5, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Prints numbered ticks, notes SIGHUP in a file, and exits with 7 on "quit".
    /// zsh, because the system bash 3.2 has no fractional `read -t`.
    private func tickerScript() -> String {
        let hup = dir.appendingPathComponent("hup").path
        return """
        trap 'echo HUP >> "\(hup)"; exit 1' HUP
        i=0
        while :; do
          i=$((i+1)); echo "tick $i"
          if read -t 0.03 line; then [ "$line" = quit ] && exit 7; echo "got:$line"; fi
        done
        """
    }

    private func ticks(_ text: String) -> [Int] {
        text.split(whereSeparator: { $0.isNewline }).compactMap { line in
            line.hasPrefix("tick ") ? Int(line.dropFirst(5)) : nil
        }
    }

    @Test func handoverKeepsTheChildAliveWithoutGapsAndReportsItsExitStatus() async throws {
        let first = Recorder()
        let p1 = LocalProcess(delegate: first)
        p1.startProcess(executable: "/bin/zsh", args: ["-c", tickerScript()])
        let pid = p1.shellPid
        await wait { ticks(first.text).count >= 5 }
        try #require(ticks(first.text).count >= 5, "Ticker-Ausgabe: \(first.text.prefix(300).debugDescription)")

        let handle = try #require(p1.detachForHandover())
        #expect(handle.pid == pid)
        #expect(!p1.running)
        #expect(fcntl(handle.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)
        let before = ticks(first.text)

        // No reader for a moment, like the gap between two hosts.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(kill(pid, 0) == 0, "child still alive")

        let second = Recorder()
        let p2 = LocalProcess(delegate: second)
        #expect(p2.adopt(handle))
        await wait { ticks(second.text).count >= 5 }
        p2.send(data: Array("hallo\n".utf8)[...])
        await wait { second.text.contains("got:hallo") }
        #expect(second.text.contains("got:hallo"))

        // Together the two hosts saw every tick exactly once, in order.
        let all = before + ticks(second.text)
        #expect(!all.isEmpty && all == Array(1...max(all.count, 1)), "Lücke oder Doppel: \(all.prefix(20))…")

        p2.send(data: Array("quit\n".utf8)[...])
        await wait { !second.exits.isEmpty }
        let status = try #require(second.exits.first ?? nil)
        #expect((status >> 8) & 0xff == 7, "Exit-Code 7 erwartet, Status \(status)")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("hup").path), "kein SIGHUP")
        #expect(first.exits.isEmpty, "der erste Host meldet nach der Abgabe kein Ende mehr")
    }

    @Test func releasingTheFirstHostAfterDetachDoesNotTouchTheChild() async throws {
        let first = Recorder()
        var p1: LocalProcess? = LocalProcess(delegate: first)
        p1!.startProcess(executable: "/bin/zsh", args: ["-c", tickerScript()])
        let pid = p1!.shellPid
        await wait { ticks(first.text).count >= 2 }
        let handle = try #require(p1!.detachForHandover())
        p1 = nil   // deinit must neither close the copy nor signal the child
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(kill(pid, 0) == 0)
        #expect(fcntl(handle.fileDescriptor, F_GETFD) >= 0, "Kopie noch offen")
        // Close the copy first: a process that exits with unread output on its
        // terminal waits in exit until someone reads or the last primary closes.
        close(handle.fileDescriptor)
        kill(pid, SIGKILL)
        waitpid(pid, nil, 0)
    }

    @Test func exitStatusOfAnAdoptedProcessThatIsNotOurChild() async throws {
        // A grandchild: not ours, waitpid cannot see it, only kqueue.
        let pidFile = dir.appendingPathComponent("pid").path
        let outer = Recorder()
        let p1 = LocalProcess(delegate: outer)
        p1.startProcess(executable: "/bin/sh", args: ["-c", "sh -c 'echo $$ > \"\(pidFile)\"; sleep 0.6; exit 5' & sleep 5"])
        await wait { FileManager.default.fileExists(atPath: pidFile) && ((try? String(contentsOfFile: pidFile, encoding: .utf8)) ?? "").hasSuffix("\n") }
        let grandchild = try #require(Int32(((try? String(contentsOfFile: pidFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        let handle = try #require(p1.detachForHandover())

        let watcher = Recorder()
        let p2 = LocalProcess(delegate: watcher)
        #expect(p2.adopt(LocalProcess.HandoverHandle(fileDescriptor: handle.fileDescriptor, pid: grandchild)))
        await wait { !watcher.exits.isEmpty }
        let status = try #require(watcher.exits.first ?? nil)
        #expect((status >> 8) & 0xff == 5, "Exit-Code 5 erwartet, Status \(status)")
        kill(handle.pid, SIGKILL)
        waitpid(handle.pid, nil, 0)
    }

    @Test func adoptingAProcessThatAlreadyEndedReportsItRightAway() async throws {
        let first = Recorder()
        let p1 = LocalProcess(delegate: first)
        p1.startProcess(executable: "/bin/sh", args: ["-c", "sleep 5"])
        let handle = try #require(p1.detachForHandover())
        kill(handle.pid, SIGKILL)
        waitpid(handle.pid, nil, 0)   // gone and collected before the takeover

        let second = Recorder()
        let p2 = LocalProcess(delegate: second)
        p2.adopt(handle)
        await wait { !second.exits.isEmpty }
        #expect(second.exits.count == 1)
        #expect(!p2.running)
    }

    @Test func ownChildStillReportsItsRealStatus() async throws {
        let rec = Recorder()
        let p = LocalProcess(delegate: rec)
        p.startProcess(executable: "/bin/sh", args: ["-c", "exit 3"])
        await wait { !rec.exits.isEmpty }
        let status = try #require(rec.exits.first ?? nil)
        #expect((status >> 8) & 0xff == 3)
    }

    @Test func detachWithoutARunningChildReturnsNil() {
        let p = LocalProcess(delegate: Recorder())
        #expect(p.detachForHandover() == nil)
    }

    @Test func childDoesNotInheritDescriptorsWithoutCloseOnExec() async throws {
        // A descriptor some library opened without the flag.
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        #expect(fcntl(fds[0], F_GETFD) & FD_CLOEXEC == 0)
        let rec = Recorder()
        let p = LocalProcess(delegate: rec)
        p.startProcess(executable: "/bin/sh", args: ["-c", "if { true <&\(fds[0]); } 2>/dev/null; then echo GEERBT; else echo FREI; fi"])
        await wait { rec.text.contains("GEERBT") || rec.text.contains("FREI") }
        #expect(rec.text.contains("FREI"), "\(rec.text)")
    }
}
#endif
