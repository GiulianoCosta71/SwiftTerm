// TEMP DEBUG — Caret-Flacker-Diagnose für WhisperM8. Diese Datei wird nach der
// Diagnose wieder entfernt. Schreibt Caret-Events direkt in /tmp/caretdbg.log,
// weil NSLog/unified-log in dieser App-Konfiguration nicht zuverlässig sichtbar war.
import Foundation

private let _caretDbgFH: FileHandle? = {
    let path = "/tmp/caretdbg.log"
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}()

func caretDbg(_ s: String) {
    guard let fh = _caretDbgFH, let d = (s + "\n").data(using: .utf8) else { return }
    fh.write(d)
}
