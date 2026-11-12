# Fixtures

`handover-*.deflate` are recordings of real terminal sessions, used by
`TerminalScreenSerializerTests`: raw output of Claude Code 2.1.322 and the
Codex CLI 0.160.1 in a 110×34 terminal, captured byte for byte. User names,
paths and account details were replaced with placeholders of the same length.
Compressed as raw DEFLATE (`zlib` with `wbits = -15`), which
`NSData.decompressed(using: .zlib)` reads.
