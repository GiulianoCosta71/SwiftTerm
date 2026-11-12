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
    /// left/right margins, character set designations and the title stack. A
    /// hyperlink still open at the end is linked again from the cursor on, not
    /// from where it started.
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
            // 1049h stores the normal cursor, pen and modes in the normal
            // buffer's saved state; recreate exactly that, then switch.
            out.scrollRegion(of: normal, rows: rows)
            out.savedState(of: normal, cols: cols)
            out.csi("?1049h")
            // Lay out the alternate screen with defaults.
            out.csi("?7h")
            out.csi("?6l")
            out.csi("?45l")
            out.csi("r")
            out.csi("H")
            out.lines(of: altBuffer, terminal: self)
            out.kittyKeyboard(keyboardModeAlt)
        }

        let active = buffer
        // Scroll region first: it homes the cursor, and origin-relative
        // positions depend on it.
        out.scrollRegion(of: active, rows: rows)
        // The saved cursor (DECSC) with the modes it stores.
        out.savedState(of: active, cols: cols)
        out.raw("\u{1b}7")

        out.csi(originMode ? "?6h" : "?6l")
        let row = originMode ? active.y - active.scrollTop : active.y
        let lineIndex = active.y + active.yBase
        if wraparound, active.x >= cols, lineIndex < active.lines.count {
            // Pending wrap: the cursor sits past the last column. Writing the
            // last cell again puts the terminal into exactly that state.
            out.cursor(row: row, col: cols - 1, cols: cols)
            out.rewriteLastCell(of: active.lines[lineIndex], cols: cols, terminal: self)
        } else {
            out.cursor(row: row, col: active.x, cols: cols)
        }

        out.csi(wraparound ? "?7h" : "?7l")
        out.csi(reverseWraparound ? "?45h" : "?45l")
        if insertMode { out.csi("4h") }
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
        // A hyperlink opened but not closed yet: open it again, so text that
        // follows is linked like in the original (from the cursor on).
        if let open = hyperLinkTracking {
            out.raw("\u{1b}]8;\(open.payload)\u{1b}\\")
        }
        out.bytes.append(contentsOf: unfinishedInput())
        return out.bytes
    }

    /// Input this terminal has read but not acted on yet: the start of an
    /// escape sequence the parser is still collecting, and the first bytes of
    /// a UTF-8 character. Feeding them after the state puts the receiver into
    /// the same position, so the next bytes from the application continue
    /// there. Empty at a clean boundary. If a sequence started longer ago than
    /// the recorded input reaches back, an unknown OSC is opened instead, so
    /// the rest of the sequence is swallowed up to its terminator rather than
    /// printed as text.
    func unfinishedInput() -> [UInt8] {
        var tail: [UInt8] = []
        if !readingBuffer.putbackBuffer.isEmpty {
            tail.append(contentsOf: readingBuffer.putbackBuffer)
        }
        if parser.currentState != .ground {
            if let start = recentInput.lastIndex(of: 0x1b) {
                tail.append(contentsOf: recentInput[start...])
            } else {
                tail.append(contentsOf: Array("\u{1b}]9999;".utf8))
            }
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

    /// DECSTBM of `buffer`, or the full screen. Homes the cursor.
    mutating func scrollRegion(of buffer: Buffer, rows: Int) {
        if buffer.scrollTop != 0 || buffer.scrollBottom != rows - 1 {
            csi("\(buffer.scrollTop + 1);\(buffer.scrollBottom + 1)r")
        } else {
            csi("r")
        }
    }

    /// Puts cursor, pen and the modes DECSC stores into the state `buffer`
    /// keeps as saved, so a following DECSC (ESC 7 or 1049h) stores the same.
    mutating func savedState(of buffer: Buffer, cols: Int) {
        csi(buffer.savedOriginMode ? "?6h" : "?6l")
        let row = buffer.savedOriginMode ? buffer.savedY - buffer.scrollTop : buffer.savedY
        cursor(row: row, col: buffer.savedX, cols: cols)
        csi(buffer.savedWraparound ? "?7h" : "?7l")
        csi(buffer.savedReverseWraparound ? "?45h" : "?45l")
        pen(buffer.savedAttr)
    }

    /// Writes the last cell of `line` again with the cursor on the last
    /// column (for a wide character: on its first half), leaving a pending wrap.
    mutating func rewriteLastCell(of line: BufferLine, cols: Int, terminal: Terminal) {
        var col = cols - 1
        if col > 0, line[col].width == 0, line[col - 1].width == 2 { col -= 1 }
        if col != cols - 1 { csi("\(col + 1)G") }
        writeCell(line[col], terminal: terminal)
        openLink(nil)
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
