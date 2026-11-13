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

        // Together the two hosts saw every tick exactly once, in order (parsed
        // together: the handover may split a line between the hosts).
        _ = before
        let all = ticks(first.text + second.text)
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
        p1.startProcess(executable: "/bin/sh", args: ["-c", "sh -c 'echo $$ > \"\(pidFile)\"; sleep 2; exit 5' & sleep 8"])
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
        try await Task.sleep(nanoseconds: 300_000_000)   // a second report would show up here
        #expect(second.exits.count == 1)
        #expect(!p2.running)
    }

    @Test func outputQueuedForDeliveryIsNotLostOrReordered() async throws {
        // A fast producer and a busy main thread: at the handover, part of the
        // output still waits in the delivery queue of the first host.
        let first = Recorder()
        let p1 = LocalProcess(delegate: first)
        p1.startProcess(executable: "/bin/sh", args: ["-c", "seq 1 200000; sleep 5"])
        await wait { first.bytes.count > 1000 }
        usleep(300_000)   // main busy, reads pile up in the delivery queue
        let handle = try #require(p1.detachForHandover())
        let second = Recorder()
        let p2 = LocalProcess(delegate: second)
        p2.adopt(handle)
        await wait(10) { String(decoding: second.bytes.suffix(16), as: UTF8.self).contains("\n200000") }
        let numbers = (first.text + second.text).split(whereSeparator: { $0.isNewline }).compactMap { Int($0) }
        #expect(numbers == Array(1...200000), "Anzahl \(numbers.count), erste Abweichung bei \(zip(numbers, 1...).first(where: { $0 != $1 }).map { "\($0)" } ?? "-")")
        kill(handle.pid, SIGKILL)
        waitpid(handle.pid, nil, 0)
    }

    @Test func pendingWriteToAChildThatDoesNotReadDoesNotBlockTheHandover() async throws {
        let rec = Recorder()
        let p1 = LocalProcess(delegate: rec)
        p1.startProcess(executable: "/bin/sh", args: ["-c", "sleep 30"])
        try await Task.sleep(nanoseconds: 200_000_000)
        // More than the terminal's input queue holds: the write stays pending.
        p1.send(data: [UInt8](repeating: UInt8(ascii: "x"), count: 512 * 1024)[...])
        try await Task.sleep(nanoseconds: 300_000_000)
        let start = Date()
        let handle = p1.detachForHandover(timeout: 2)
        let elapsed = Date().timeIntervalSince(start)
        #expect(handle != nil)
        #expect(elapsed < 1, "Abgabe wartete \(elapsed) s auf den hängenden Schreibauftrag")
        if let handle {
            close(handle.fileDescriptor)
            kill(handle.pid, SIGKILL)
            waitpid(handle.pid, nil, 0)
        }
    }

    @Test func adoptingAZombieReportsItsExit() async throws {
        // After the handover nobody collects the child; it ends and stays a
        // zombie until the next host adopts it.
        let first = Recorder()
        let p1 = LocalProcess(delegate: first)
        p1.startProcess(executable: "/bin/sh", args: ["-c", "sleep 0.3; exit 4"])
        let handle = try #require(p1.detachForHandover())
        try await Task.sleep(nanoseconds: 900_000_000)
        let second = Recorder()
        let p2 = LocalProcess(delegate: second)
        p2.adopt(handle)
        await wait { !second.exits.isEmpty }
        #expect(second.exits.count == 1, "Ende eines Zombies nicht gemeldet")
        if let status = second.exits.first ?? nil {
            #expect((status >> 8) & 0xff == 4)
        }
    }

    @Test func ownChildStillReportsItsRealStatus() async throws {
        let rec = Recorder()
        let p = LocalProcess(delegate: rec)
        p.startProcess(executable: "/bin/sh", args: ["-c", "exit 3"])
        await wait { !rec.exits.isEmpty }
        let status = try #require(rec.exits.first ?? nil)
        #expect((status >> 8) & 0xff == 3)
    }

    // Review 13.11.2026, Befund 1: only "no such process" counts as ended.
    @Test func adoptFailsWhenTheExitCannotBeWatched() throws {
        // launchd (PID 1) belongs to root: kqueue refuses the watch with a
        // permission error, not "no such process".
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let rec = Recorder()
        let p = LocalProcess(delegate: rec)
        #expect(!p.adopt(LocalProcess.HandoverHandle(fileDescriptor: fds[0], pid: 1)))
        #expect(!p.running)
        #expect(p.shellPid == 0)
        #expect(fcntl(fds[0], F_GETFD) >= 0, "der Aufrufer behält die Leitung")
        #expect(rec.exits.isEmpty, "kein erfundenes Ende")
    }

    // Review 13.11.2026, Befund 2: after a detach that ran out of time, the
    // next one must still wait for the outstanding read. Repeated, because a
    // detach only times out while a read is actually in flight.
    @Test func detachAfterATimedOutDetachLosesNothing() async throws {
        let first = Recorder()
        let p1 = LocalProcess(delegate: first)
        p1.startProcess(executable: "/bin/sh", args: ["-c", "seq 1 300000; sleep 5"])
        await wait { first.bytes.count > 1000 }
        var timedOut = 0
        var early: LocalProcess.HandoverHandle?
        for _ in 0..<50 where timedOut < 3 {
            // Succeeds when no read happens to be in flight; then that handle
            // is the handover and the check below still applies.
            if let handle = p1.detachForHandover(timeout: 0) { early = handle; break }
            timedOut += 1
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        // After timeouts, a normal detach still hands over cleanly.
        let handle = try early ?? #require(p1.detachForHandover())
        let second = Recorder()
        let p2 = LocalProcess(delegate: second)
        #expect(p2.adopt(handle))
        await wait(15) { String(decoding: second.bytes.suffix(16), as: UTF8.self).contains("\n300000") }
        let numbers = (first.text + second.text).split(whereSeparator: { $0.isNewline }).compactMap { Int($0) }
        #expect(numbers == Array(1...300000), "Anzahl \(numbers.count), Zeitüberschreitungen \(timedOut)")
        kill(handle.pid, SIGKILL)
        waitpid(handle.pid, nil, 0)
    }

    // Review 13.11.2026, Befund 7: the rebuilt read loop under a flood.
    @Test func floodOfOutputArrivesCompletely() async throws {
        let rec = Recorder()
        let p = LocalProcess(delegate: rec)
        p.startProcess(executable: "/bin/sh", args: ["-c", "/usr/bin/yes | /usr/bin/head -n 2000000"])
        let deadline = Date().addingTimeInterval(60)
        while rec.exits.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // The terminal turns each newline into CR LF; count the lines instead.
        await wait(60) { rec.bytes.filter { $0 == 0x79 }.count >= 2_000_000 }
        #expect(rec.bytes.filter { $0 == 0x79 }.count == 2_000_000, "Zeilen \(rec.bytes.filter { $0 == 0x79 }.count)")
        #expect(rec.bytes.allSatisfy { $0 == 0x79 || $0 == 0x0a || $0 == 0x0d })
        #expect(rec.exits.count == 1)
    }

    @Test func detachWithoutARunningChildReturnsNil() {
        let p = LocalProcess(delegate: Recorder())
        #expect(p.detachForHandover() == nil)
    }

    @Test func childDoesNotInheritDescriptorsWithoutCloseOnExec() async throws {
        // A descriptor some library opened without the flag.
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        // On a high number: a low one could be handed out again inside the
        // child (the shell opens files of its own), which would look inherited.
        let probe = fcntl(fds[0], F_DUPFD, 400)
        close(fds[0])
        defer { close(probe); close(fds[1]) }
        #expect(probe >= 400)
        #expect(fcntl(probe, F_GETFD) & FD_CLOEXEC == 0)
        let rec = Recorder()
        let p = LocalProcess(delegate: rec)
        p.startProcess(executable: "/bin/sh", args: ["-c", "if { true <&\(probe); } 2>/dev/null; then echo GEERBT; else echo FREI; fi"])
        await wait { rec.text.contains("GEERBT") || rec.text.contains("FREI") }
        #expect(rec.text.contains("FREI"), "\(rec.text)")
    }
}
#endif
