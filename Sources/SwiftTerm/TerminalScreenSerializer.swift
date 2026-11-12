//
//  TerminalScreenSerializer.swift
//
//  Serializes the complete state a client sees (scrollback, screen, alternate
//  screen, cursor and the modes an application sets once at startup) into a
//  byte stream. Feeding that stream into a fresh Terminal with the same
//  cols, rows and scrollback reproduces the state, so a terminal can be
//  handed over to another process without the application noticing.
//
import Foundation

extension Terminal {
    /// Returns an ANSI byte stream that recreates this terminal.
    ///
    /// Contract: create a new `Terminal` with the same `cols`, `rows` and
    /// scrollback and pass the result to `feed(byteArray:)`; nothing else.
    ///
    /// Covered: every line of the normal buffer including scrollback and soft
    /// wraps, characters (wide characters, grapheme clusters), colors (256 and
    /// true color), styles, underline style and color, hyperlinks (OSC 8),
    /// the alternate screen together with the normal buffer below it, cursor
    /// position and saved cursor, scroll region, origin mode, cursor style and
    /// visibility, bracketed paste, focus reporting, application cursor and
    /// keypad, mouse tracking with its encoding, the kitty keyboard flags and
    /// their stack for both screens, wraparound and insert mode, and the
    /// current pen.
    ///
    /// A sequence or UTF-8 character cut at the end of the input so far is
    /// carried on as well (see `unfinishedInput`).
    ///
    /// Not covered: images (sixel, kitty graphics), palette changes (OSC 4),
    /// left/right margins, character set designations, the title stack, and a
    /// pending wrap at the right edge (the cursor is placed on the last column).
    /// Has no view dependency and does not change the terminal.
    public func serializeScreen() -> [UInt8] {
        var out = ScreenStream()
        // A fresh terminal starts in wraparound mode without insert mode; set
        // both explicitly so content is laid out the same way regardless.
        out.csi("?7h")
        out.csi("4l")

        let normal = normalBuffer
        out.lines(of: normal, terminal: self)
        out.kittyKeyboard(keyboardModeNormal)

        if isCurrentBufferAlternate {
            // Park the normal cursor where it was; 1049h saves it for the
            // application's own switch back.
            out.cursor(row: normal.y, col: normal.x, cols: cols)
            out.csi("?1049h")
            out.csi("H")
            out.lines(of: altBuffer, terminal: self)
            out.kittyKeyboard(keyboardModeAlt)
        }

        let active = buffer
        // Saved cursor (DECSC) first: positioning it moves the cursor.
        out.cursor(row: active.savedY, col: active.savedX, cols: cols)
        out.pen(active.savedAttr)
        out.raw("\u{1b}7")

        // Scroll region homes the cursor, so it comes before the final position.
        if active.scrollTop != 0 || active.scrollBottom != rows - 1 {
            out.csi("\(active.scrollTop + 1);\(active.scrollBottom + 1)r")
        }
        if originMode {
            out.csi("?6h")
            out.cursor(row: active.y - active.scrollTop, col: active.x, cols: cols)
        } else {
            out.cursor(row: active.y, col: active.x, cols: cols)
        }

        if !wraparound { out.csi("?7l") }
        if insertMode { out.csi("4h") }
        if reverseWraparound { out.csi("?45h") }
        if applicationCursor { out.csi("?1h") }
        if applicationKeypad { out.raw("\u{1b}=") }
        if bracketedPasteMode { out.csi("?2004h") }
        if sendFocus { out.csi("?1004h") }
        switch mouseMode {
        case .off: break
        case .x10: out.csi("?9h")
        case .vt200: out.csi("?1000h")
        case .buttonEventTracking: out.csi("?1002h")
        case .anyEvent: out.csi("?1003h")
        }
        switch mouseProtocol {
        case .x10: break
        case .utf8: out.csi("?1005h")
        case .sgr: out.csi("?1006h")
        case .urxvt: out.csi("?1015h")
        case .sgrPixel: out.csi("?1016h")
        }
        out.csi("\(Self.decscusr(options.cursorStyle)) q")
        if cursorHidden { out.csi("?25l") }
        out.pen(curAttr)
        out.bytes.append(contentsOf: unfinishedInput())
        return out.bytes
    }

    /// Input this terminal has read but not acted on yet: the start of an
    /// escape sequence the parser is still collecting, and the first bytes of
    /// a UTF-8 character. Feeding them after the state puts the receiver into
    /// the same position, so the next bytes from the application continue
    /// there. Empty when the parser is at a clean boundary, and when the
    /// sequence started longer ago than the recorded input reaches back.
    func unfinishedInput() -> [UInt8] {
        var tail: [UInt8] = []
        if !readingBuffer.putbackBuffer.isEmpty {
            tail.append(contentsOf: readingBuffer.putbackBuffer)
        }
        if parser.currentState != .ground,
           let start = recentInput.lastIndex(of: 0x1b) {
            tail.append(contentsOf: recentInput[start...])
        }
        return tail
    }

    static func decscusr(_ style: CursorStyle) -> Int {
        switch style {
        case .blinkBlock: return 1
        case .steadyBlock: return 2
        case .blinkUnderline: return 3
        case .steadyUnderline: return 4
        case .blinkBar: return 5
        case .steadyBar: return 6
        }
    }
}

/// Byte builder for `serializeScreen`.
private struct ScreenStream {
    var bytes: [UInt8] = []
    private var pen: Attribute? = nil
    private var link: TinyAtom? = nil

    mutating func raw(_ s: String) { bytes.append(contentsOf: Array(s.utf8)) }
    mutating func csi(_ s: String) { raw("\u{1b}[" + s) }

    mutating func cursor(row: Int, col: Int, cols: Int) {
        csi("\(max(row, 0) + 1);\(min(max(col, 0), cols - 1) + 1)H")
    }

    /// Selects `attribute` as the current pen (always written, so the result
    /// does not depend on what was emitted before).
    mutating func pen(_ attribute: Attribute) {
        raw(Self.sgr(attribute))
        pen = attribute
    }

    private mutating func penIfChanged(_ attribute: Attribute) {
        if pen != attribute { pen(attribute) }
    }

    private mutating func openLink(_ atom: TinyAtom?) {
        guard atom?.code != link?.code else { return }
        if link != nil { raw("\u{1b}]8;;\u{1b}\\") }
        if let atom, let payload = atom.target as? String {
            raw("\u{1b}]8;\(payload)\u{1b}\\")
            link = atom
        } else {
            link = nil
        }
    }

    private static func isBlank(_ c: CharData) -> Bool {
        (c.code == 0 || c.code == 32) && c.attribute == CharData.defaultAttr && !c.hasPayload
    }

    /// All lines of `buffer`, joined with CR LF unless the next line is a soft
    /// wrap of this one (then the line is written to the full width and the
    /// terminal wraps on its own, which sets the wrap flag).
    mutating func lines(of buffer: Buffer, terminal: Terminal) {
        let count = buffer.lines.count
        for i in 0..<count {
            let line = buffer.lines[i]
            let nextWrapped = i + 1 < count && buffer.lines[i + 1].isWrapped
            var end = line.count
            if !nextWrapped {
                while end > 0, Self.isBlank(line[end - 1]) { end -= 1 }
            }
            var col = 0
            while col < end {
                let cell = line[col]
                if cell.width == 0 { col += 1; continue }   // right half of a wide character
                writeCell(cell, terminal: terminal)
                col += 1
            }
            openLink(nil)
            if i + 1 < count, !nextWrapped {
                if pen != nil, pen != CharData.defaultAttr { pen(CharData.defaultAttr) }
                raw("\r\n")
            }
        }
        openLink(nil)
    }

    private mutating func writeCell(_ cell: CharData, terminal: Terminal) {
        openLink(cell.hasPayload ? cell.payload : nil)
        penIfChanged(cell.attribute)
        if cell.code == 0 {
            raw(" ")
        } else {
            raw(String(terminal.getCharacter(for: cell)))
        }
    }

    /// Recreates flags and stack: the bottom entry becomes the current flags,
    /// every further entry and finally the current flags are pushed on top.
    mutating func kittyKeyboard(_ state: Terminal.KeyboardModeState) {
        let all = state.stack + [state.flags]
        guard all.contains(where: { $0.rawValue != 0 }) else { return }
        csi("=\(all[0].rawValue);1u")
        for flags in all.dropFirst() {
            csi(">\(flags.rawValue)u")
        }
    }

    static func sgr(_ a: Attribute) -> String {
        var p: [String] = ["0"]
        let st = a.style
        if st.contains(.bold) { p.append("1") }
        if st.contains(.dim) { p.append("2") }
        if st.contains(.italic) { p.append("3") }
        if st.contains(.underline) {
            switch a.underlineStyle {
            case .none, .single: p.append("4")
            default: p.append("4:\(a.underlineStyle.rawValue)")
            }
        }
        if st.contains(.blink) { p.append("5") }
        if st.contains(.inverse) { p.append("7") }
        if st.contains(.invisible) { p.append("8") }
        if st.contains(.crossedOut) { p.append("9") }
        switch a.fg {
        case .ansi256(let c): p.append("38;5;\(c)")
        case .trueColor(let r, let g, let b): p.append("38;2;\(r);\(g);\(b)")
        case .defaultColor, .defaultInvertedColor: break
        }
        switch a.bg {
        case .ansi256(let c): p.append("48;5;\(c)")
        case .trueColor(let r, let g, let b): p.append("48;2;\(r);\(g);\(b)")
        case .defaultColor, .defaultInvertedColor: break
        }
        if let uc = a.underlineColor {
            switch uc {
            case .ansi256(let c): p.append("58;5;\(c)")
            case .trueColor(let r, let g, let b): p.append("58;2;\(r);\(g);\(b)")
            default: break
            }
        }
        return "\u{1b}[" + p.joined(separator: ";") + "m"
    }
}
