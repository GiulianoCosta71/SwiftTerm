import Foundation
import Testing
@testable import SwiftTerm

/// `Terminal.serializeScreen()`: a fresh terminal with the same size that is fed
/// the stream must be indistinguishable from the original, now and after
/// further output.
final class TerminalScreenSerializerTests {
    private let esc = "\u{1b}"

    // MARK: Helpers

    private func make(_ cols: Int, _ rows: Int, _ scrollback: Int) -> Terminal {
        TerminalTestHarness.makeTerminal(cols: cols, rows: rows, scrollback: scrollback).terminal
    }

    private func restored(from original: Terminal, scrollback: Int) -> Terminal {
        let copy = make(original.cols, original.rows, scrollback)
        copy.feed(byteArray: original.serializeScreen())
        return copy
    }

    /// Everything that differs, as readable lines; empty when equal.
    private func differences(_ a: Terminal, _ b: Terminal) -> [String] {
        var out: [String] = []
        func compare(_ ba: Buffer, _ bb: Buffer, _ name: String) {
            if ba.lines.count != bb.lines.count {
                out.append("\(name): \(ba.lines.count) gegen \(bb.lines.count) Zeilen")
            }
            let n = min(ba.lines.count, bb.lines.count)
            for i in 0..<n {
                let la = ba.lines[i], lb = bb.lines[i]
                if la.isWrapped != lb.isWrapped { out.append("\(name) Zeile \(i): Umbruch \(la.isWrapped) gegen \(lb.isWrapped)") }
                for c in 0..<min(la.count, lb.count) {
                    let ca = la[c], cb = lb[c]
                    let chA = ca.code == 0 ? " " : String(a.getCharacter(for: ca))
                    let chB = cb.code == 0 ? " " : String(b.getCharacter(for: cb))
                    if chA != chB { out.append("\(name) \(i):\(c) Zeichen \(chA.debugDescription) gegen \(chB.debugDescription)") }
                    else if ca.width != cb.width { out.append("\(name) \(i):\(c) Breite \(ca.width) gegen \(cb.width)") }
                    else if ca.attribute != cb.attribute { out.append("\(name) \(i):\(c) Attribut") }
                    else if (ca.hasPayload ? ca.payload.target as? String : nil) != (cb.hasPayload ? cb.payload.target as? String : nil) {
                        out.append("\(name) \(i):\(c) Link")
                    }
                    if out.count > 20 { return }
                }
            }
        }
        compare(a.normalBuffer, b.normalBuffer, "normal")
        if a.isCurrentBufferAlternate || b.isCurrentBufferAlternate { compare(a.altBuffer, b.altBuffer, "alt") }
        func check(_ label: String, _ x: String, _ y: String) { if x != y { out.append("\(label): \(x) gegen \(y)") } }
        check("alt aktiv", "\(a.isCurrentBufferAlternate)", "\(b.isCurrentBufferAlternate)")
        check("Cursor", "\(a.buffer.x),\(a.buffer.y)", "\(b.buffer.x),\(b.buffer.y)")
        check("gesicherter Cursor", "\(a.buffer.savedX),\(a.buffer.savedY)", "\(b.buffer.savedX),\(b.buffer.savedY)")
        check("Scrollbereich", "\(a.buffer.scrollTop)-\(a.buffer.scrollBottom)", "\(b.buffer.scrollTop)-\(b.buffer.scrollBottom)")
        check("Cursor versteckt", "\(a.cursorHidden)", "\(b.cursorHidden)")
        check("Bracketed Paste", "\(a.bracketedPasteMode)", "\(b.bracketedPasteMode)")
        check("Fokus", "\(a.sendFocus)", "\(b.sendFocus)")
        check("App-Cursor", "\(a.applicationCursor)", "\(b.applicationCursor)")
        check("App-Keypad", "\(a.applicationKeypad)", "\(b.applicationKeypad)")
        check("Maus", "\(a.mouseMode)", "\(b.mouseMode)")
        check("Mauskodierung", "\(a.mouseProtocol)", "\(b.mouseProtocol)")
        check("Kitty normal", "\(a.keyboardModeNormal.stack.map(\.rawValue))/\(a.keyboardModeNormal.flags.rawValue)",
              "\(b.keyboardModeNormal.stack.map(\.rawValue))/\(b.keyboardModeNormal.flags.rawValue)")
        if a.isCurrentBufferAlternate {
            check("Kitty alt", "\(a.keyboardModeAlt.stack.map(\.rawValue))/\(a.keyboardModeAlt.flags.rawValue)",
                  "\(b.keyboardModeAlt.stack.map(\.rawValue))/\(b.keyboardModeAlt.flags.rawValue)")
        }
        check("Wraparound", "\(a.wraparound)", "\(b.wraparound)")
        check("Origin", "\(a.originMode)", "\(b.originMode)")
        check("Einfügen", "\(a.insertMode)", "\(b.insertMode)")
        check("Stift", "\(a.curAttr)", "\(b.curAttr)")
        check("Cursorstil", "\(a.options.cursorStyle)", "\(b.options.cursorStyle)")
        return out
    }

    /// Restores at the current point, then feeds `more` into both and compares again.
    private func expectRoundTrip(_ original: Terminal, scrollback: Int, then more: String = "") {
        let copy = restored(from: original, scrollback: scrollback)
        let now = differences(original, copy)
        #expect(now.isEmpty, "direkt nach dem Einspielen: \(now)")
        guard !more.isEmpty else { return }
        original.feed(text: more)
        copy.feed(text: more)
        let later = differences(original, copy)
        #expect(later.isEmpty, "nach weiterer Ausgabe: \(later)")
    }

    // MARK: Content

    @Test func scrollbackAndScreenSurvive() {
        let t = make(40, 10, 200)
        for i in 1...120 { t.feed(text: "Zeile \(i)\r\n") }
        t.feed(text: "Prompt> ")
        expectRoundTrip(t, scrollback: 200, then: "weiter\r\nnoch eine Zeile")
    }

    @Test func colorsStylesAndUnderlines() {
        let t = make(60, 8, 50)
        t.feed(text: "\(esc)[1;3;31mfett kursiv rot\(esc)[0m \(esc)[38;5;208;48;5;19morange auf blau\(esc)[0m\r\n")
        t.feed(text: "\(esc)[38;2;10;200;30;48;2;1;2;3mtruecolor\(esc)[0m \(esc)[4:3;58;2;255;0;0mwellig rot\(esc)[0m\r\n")
        t.feed(text: "\(esc)[2;5;7;8;9mrest\(esc)[0m \(esc)[4:2mdoppelt\(esc)[0m \(esc)[44m    \(esc)[0m\r\n")
        t.feed(text: "\(esc)[32mStift bleibt gesetzt")
        expectRoundTrip(t, scrollback: 50, then: " und schreibt grün weiter")
    }

    @Test func wideCharactersAndGraphemes() {
        let t = make(20, 6, 20)
        t.feed(text: "日本語テキスト\r\n")
        t.feed(text: "e\u{301}ü 👍🏽 👨‍👩‍👧\r\n")
        t.feed(text: "1234567890123456789日\r\n")   // wide character that has to wrap
        expectRoundTrip(t, scrollback: 20, then: "末")
    }

    @Test func softWrappedLinesStayOneLogicalLine() {
        let t = make(10, 5, 20)
        t.feed(text: String(repeating: "abcdefghij", count: 3) + "xyz\r\nkurz")
        let copy = restored(from: t, scrollback: 20)
        #expect(differences(t, copy).isEmpty)
        // Reflow after a resize only works if the wrap flags are right.
        t.resize(cols: 15, rows: 5)
        copy.resize(cols: 15, rows: 5)
        #expect(differences(t, copy).isEmpty)
    }

    @Test func hyperlinksAreKept() {
        let t = make(50, 5, 10)
        t.feed(text: "Datei: \(esc)]8;;file:///tmp/a.swift\(esc)\\a.swift\(esc)]8;;\(esc)\\ fertig\r\n")
        t.feed(text: "\(esc)]8;id=x;https://example.com\(esc)\\Link mit id\(esc)]8;;\(esc)\\ ende")
        expectRoundTrip(t, scrollback: 10, then: "\r\nnoch mehr")
    }

    // MARK: Alternate screen

    @Test func alternateScreenWithNormalBufferBelow() {
        let t = make(30, 8, 50)
        for i in 1...20 { t.feed(text: "Verlauf \(i)\r\n") }
        t.feed(text: "\(esc)[?1049h\(esc)[H\(esc)[2J\(esc)[7mKopfzeile\(esc)[0m\(esc)[5;3HMitte\(esc)[8;1HFuß")
        expectRoundTrip(t, scrollback: 50, then: "\(esc)[3;3Hneu")
    }

    @Test func leavingTheAlternateScreenRestoresTheNormalCursor() {
        let t = make(30, 8, 50)
        t.feed(text: "erste Zeile\r\nzweite Zeile\r\nPrompt> ")
        t.feed(text: "\(esc)[?1049h\(esc)[Hvoll")
        expectRoundTrip(t, scrollback: 50, then: "\(esc)[?1049lweiter nach dem Verlassen")
    }

    // MARK: Modes

    @Test func modesAnApplicationSetsAtStartup() {
        let t = make(40, 10, 20)
        t.feed(text: "\(esc)[?2004h\(esc)[?1004h\(esc)[?1h\(esc)=\(esc)[?1002h\(esc)[?1006h\(esc)[?25l\(esc)[5 q")
        t.feed(text: "\(esc)[>1u\(esc)[>5u")   // two pushes like a nested TUI
        t.feed(text: "Hallo")
        expectRoundTrip(t, scrollback: 20)
        // Popping must reach the same flags as in the original.
        let copy = restored(from: t, scrollback: 20)
        t.feed(text: "\(esc)[<u"); copy.feed(text: "\(esc)[<u")
        #expect(t.keyboardEnhancementFlags == copy.keyboardEnhancementFlags)
        t.feed(text: "\(esc)[<u"); copy.feed(text: "\(esc)[<u")
        #expect(t.keyboardEnhancementFlags == copy.keyboardEnhancementFlags)
        #expect(t.keyboardEnhancementFlags.rawValue == 0)
    }

    @Test func kittyFlagsOfBothScreens() {
        let t = make(40, 10, 20)
        t.feed(text: "\(esc)[>5u\(esc)[?1049h\(esc)[>7u\(esc)[?1003h\(esc)[?1006h")
        expectRoundTrip(t, scrollback: 20, then: "\(esc)[?1049l")
    }

    @Test func scrollRegionSavedCursorAndOriginMode() {
        let t = make(30, 10, 20)
        t.feed(text: "\(esc)[3;8r\(esc)[5;4H\(esc)[33m\(esc)7\(esc)[0m\(esc)[2;2Hx")
        expectRoundTrip(t, scrollback: 20, then: "\(esc)8y\n\n\n\n\n\nscrollt im Bereich")
        let o = make(30, 10, 20)
        o.feed(text: "\(esc)[2;6r\(esc)[?6h\(esc)[3;5Hz")
        expectRoundTrip(o, scrollback: 20, then: "\(esc)[1;1Hoben im Bereich")
    }

    @Test func wraparoundAndInsertModeOff() {
        let t = make(10, 4, 10)
        t.feed(text: "\(esc)[?7l\(esc)[4habcdef")
        expectRoundTrip(t, scrollback: 10, then: "\(esc)[1;1HXYZ1234567890")
    }

    @Test func sequenceCutInTheMiddleContinuesInTheCopy() {
        let t = make(40, 6, 10)
        t.feed(text: "vorher \(esc)[38;2;200")          // CSI cut in the middle
        let copy = restored(from: t, scrollback: 10)
        t.feed(text: ";10;10mfarbig"); copy.feed(text: ";10;10mfarbig")
        #expect(differences(t, copy).isEmpty)
        let u = make(40, 6, 10)
        u.feed(byteArray: Array("ü".utf8).prefix(1) + [])  // first byte of a two-byte character
        let ucopy = restored(from: u, scrollback: 10)
        u.feed(byteArray: Array(Array("ü".utf8).suffix(1)) + Array("ber".utf8))
        ucopy.feed(byteArray: Array(Array("ü".utf8).suffix(1)) + Array("ber".utf8))
        #expect(differences(u, ucopy).isEmpty)
        let o = make(40, 6, 10)
        o.feed(text: "\(esc)]8;;https://exa")                  // OSC cut in the middle
        let ocopy = restored(from: o, scrollback: 10)
        o.feed(text: "mple.com\(esc)\\Link\(esc)]8;;\(esc)\\"); ocopy.feed(text: "mple.com\(esc)\\Link\(esc)]8;;\(esc)\\")
        #expect(differences(o, ocopy).isEmpty)
    }

    @Test func serializingDoesNotChangeTheTerminal() {
        let t = make(30, 6, 20)
        t.feed(text: "\(esc)[?1049h\(esc)[31mrot\(esc)[?2004h")
        let before = t.serializeScreen()
        _ = t.serializeScreen()
        #expect(t.serializeScreen() == before)
        #expect(t.isCurrentBufferAlternate)
    }

    // MARK: Recordings of real sessions

    private func fixture(_ name: String) throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).deflate")
        let packed = try Data(contentsOf: url) as NSData
        return [UInt8](try packed.decompressed(using: .zlib) as Data)
    }

    /// Takes over at `points` places of the recording, also in the middle of
    /// escape sequences and UTF-8 characters, and lets both terminals process
    /// the next stretch of the recording.
    private func replay(_ name: String, cols: Int, rows: Int, points: Int, window: Int) throws {
        let bytes = try fixture(name)
        let scrollback = 2_000
        var failures: [String] = []
        var midSequence = 0
        for k in 1...points {
            let cut = bytes.count * k / (points + 1) + (k % 7)   // irregular offsets
            let original = make(cols, rows, scrollback)
            original.feed(byteArray: Array(bytes[..<cut]))
            if !original.unfinishedInput().isEmpty { midSequence += 1 }
            let copy = make(cols, rows, scrollback)
            copy.feed(byteArray: original.serializeScreen())
            let next = Array(bytes[cut..<min(bytes.count, cut + window)])
            var d = differences(original, copy)
            if d.isEmpty {
                original.feed(byteArray: next)
                copy.feed(byteArray: next)
                d = differences(original, copy)
            }
            if !d.isEmpty { failures.append("Schnitt bei \(cut): \(d.prefix(3))") }
        }
        #expect(failures.isEmpty, "\(failures.count) von \(points) Schnitten weichen ab: \(failures.prefix(3))")
        #expect(midSequence > 0, "kein Schnitt lag mitten in einer Sequenz, der schwierige Fall bliebe ungeprüft")
    }

    @Test func claudeCodeRecording() throws {
        try replay("handover-claude-110x34", cols: 110, rows: 34, points: 48, window: 6_000)
    }

    @Test func codexRecording() throws {
        try replay("handover-codex-110x34", cols: 110, rows: 34, points: 48, window: 6_000)
    }
}
