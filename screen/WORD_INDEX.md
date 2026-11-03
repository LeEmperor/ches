# Asynchronous completion word index

`Ui_state.take_word_index_request` returns the latest desired snapshot (or `None`
to cancel). Call it after each frontend transition and pass the result to
`Word_index_host.follow`. `Word_index_host.next` delivers `(request, words)`;
inject it through `Ui_state.receive_word_index`.

Requests carry buffer/document identity, immutable text, and the original
completion request (token and cursor). Results cache only for a still-open
document. A menu is updated only for its exact token/cursor/revision and before
any candidate is installed. Snippets and LSP start immediately without words.

The host keeps one active base build and one latest desired snapshot. Typing in
the same document does not restart the base build. After finishing it, catch up
to the latest snapshot; switching documents or closing cancels at the next yield.
Each builder step uses a 16 KiB work budget before an Async scheduler yield.
The budget charges scalar bytes, key copying and worst-case balanced-tree
comparison estimates; a step can overshoot by one scalar and one atomic map
operation with a key capped at 4096 bytes. Small snapshots (at most 16 KiB)
first try one budgeted step synchronously. Rendering never starts or advances a
build.

Warm updates first try one bounded step. This includes comparison work: they
use `Text_buffer.recent_changed_range` for the bounded edit-history lookup, and
do not call `Text_buffer.changed_range`, whose unrelated/history-gap fallback
can scan the entire file. Recent local edits therefore catch up without comparing
unchanged file bytes. Larger comparisons, expanded identifier boundaries, and
large edit regions continue asynchronously. Updates remove/add only words in
the changed range once the yielded comparison completes. Identifiers exceeding
4096 bytes are omitted, keeping key allocation and tree comparisons bounded.

## Measurement

Run `dune exec -j6 ui/picker_test/bench_word_index.exe`. One local run on an
8,000,001-byte buffer with 400,000 distinct identifiers measured:

* first input/query transition: 13.828 ms, **zero** bytes word-tokenized;
* asynchronous build: 501.462 ms, 17,895 scheduler heartbeat turns;
* largest heartbeat gap: 2.130 ms; eventual menu: 100 candidates.

The first transition includes ordinary editor edits and screen lifecycle work.
Heartbeat gaps include allocation/GC and competing scheduler work; these are
observations, not real-time guarantees. This is a headless scheduler benchmark,
not a terminal input-to-paint latency measurement. No `In_thread` CPU scan is
used, so responsiveness does not depend on runtime-lock handoff.

Typing preserves the in-flight base build, then coalesces to the newest desired
snapshot, using the completed base index. Completed bases remain useful cache
even when their token is stale. Sustained edits faster than catch-up can defer
the exact-current word menu; snippets/LSP remain available and indexing progress
is not discarded. There is no unbounded pending-snapshot/reply queue.
