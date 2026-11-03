# Asynchronous navigation source previews

`Navigation_preview_host` follows screen-issued requests; its identity is the
exact generation and target, independently of file-picker preview generations.
The frontend follows after every input transition (including intermediate inputs
in a batch), receives replies against the current state, and invalidates the
frame cache for preview deliveries. Rendering alone does not schedule reads.
Closing/empty/exited navigation clears pending delivery; deactivation/exit stops
the host without awaiting the disk thread.

The default debounce is 40 ms. After debounce, the retained-buffer callback is
consulted against the currently installed UI state. Every returned state is
authoritative, including invalid/unavailable results. Exceptions become an
unreadable state rather than falling back to disk. The callback captures no
controller or full text in queued requests. Preview work never opens a session
buffer, activates a document, submits a source request, highlights a whole file,
or records history.

There is one active physical disk read and one newest pending request. Selection
changes set an atomic cancellation flag, checked by the model before every chunk
and during scanning. A 2-second deadline delivers an unreadable state and cancels
the read. The disk slot remains occupied until the actual worker returns, even
after a timeout or clear. A retained-buffer result can bypass that occupied slot.
`finished` is an optional testing/drain aid, never awaited by UI shutdown.

Disk reads pre-stat, open nonblocking/close-on-exec, fstat before collection, and
reject nonregular files both before and after open. Every opened descriptor is
closed in a protected finalizer. The model collector enforces 8 MiB scan, 32
lines, 4096 bytes per line, and 64 KiB output; the host uses chunked descriptor
reads without whole-file or unbounded line reads.

Freshness compares device, inode, size, mtime, and ctime, matching the fields of
`Ches_app.Navigation_file_stamp`. The disk payload stamp serializes that tuple.
Pre-stat must match opened-descriptor metadata; descriptor and path metadata are
rechecked after collection. Changes produce an explicit unreadable state instead
of a stale window. This metadata policy detects ordinary edits/replacements, but
cannot exclude a change racing the observations or a rewrite preserving metadata.

Tests in `picker_test/test_navigation_preview_host.ml` cover deferred A-B-A reads,
coalescing, stable repeated follows, timeout delivery with an occupied disk slot,
authoritative retained results, far-line disk extraction, budgets, missing/read
errors, FIFO/directory/device rejection and cancellation. The frontend test uses
the real asynchronous source/event pump to check rendered selection changes,
dirty retained text, batched transitions, stable redraws and no navigation jumps.
