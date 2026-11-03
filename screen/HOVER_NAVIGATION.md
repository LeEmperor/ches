# Pure hover and navigation integration

`Hover_tile.create hover` captures a reply. Its `spec` is read-only; `fit`,
`scroll`, and `render` take the content viewport width/rows (excluding shell).
Route `interpret` actions: `Scroll motion` calls `scroll`; `Close` dismisses the
popup and restores the host's origin. Escape and q produce `Close`. Shared
navigation supplies j/k, Ctrl-d/u, gg/G; Ctrl-e/y also scroll one row.
Rendering wraps by terminal cells, clips tiny viewports, sanitizes terminal
controls, and bounds long lines and combining runs. Markdown headings, lists,
and fenced code are readable; fence language labels and link text/URLs remain
visible. No link is executed. Hover ranges are informational only.
Local limits are 256 KiB of content, 4096 bytes per logical line, 16 consecutive
zero-width scalars, and 4096 cells per wrapped row. Elision is visibly marked.

`Destination_picker_tile` follows `Snippet_picker_tile`: `create targets`,
`fit ~rows`, `update ~rows event`, `cursor ~width`, `render ~width ~rows`.
`interpret` returns `Palette_tile.action`; the host handles accept/cancel.
`selected` returns the exact captured target, including encoding and both ranges.
Identity is the original list index, never a display string or path alone.
Search covers path and one-based selection line/character. Display labels the
one-based **character**, not a terminal display column, and includes encoding.

`Jump_history.empty` is pure. After a successful jump call
`record history ~origin ~destination`. For traversal call `peek_back` or
`peek_forward` with the actual current cursor; validate/open/reveal the returned
location, then and only then install the returned history. Failure leaves the
original history intact. Ordinary movement since a jump is preserved for reverse
traversal. New jumps truncate the forward branch; adjacent duplicates and
no-op jumps are suppressed; each direction is bounded to 128 locations.

Locations hold path and byte offset, with no document snapshots or edit tracking.
After edits offsets retain their numeric value. The host must reject offsets
outside the current document (and invalid character boundaries) rather than
silently clamp, and must reject unavailable paths without mutating history.
