# Whole-buffer word cache

Interactive completion uses the yielded `Buffer_words.Builder` and
`ui/word_index_host.ml`; see [`screen/WORD_INDEX.md`](../screen/WORD_INDEX.md)
for lifecycle, limits, and first-query/scheduler measurements. `Model.start`
accepts missing words, and `Model.receive_words` merges the eventual exact-request
result before installation. The synchronous APIs below remain available for
batch callers and benchmarks; the screen never uses unbounded `update`.

The host keeps one `Model.Buffer_words.t` per live buffer:

```ocaml
let words = Buffer_words.create text in
(* After edits, undo/redo, or changing to another snapshot of this buffer: *)
let words = Buffer_words.update words new_text in
let items = Buffer_words.candidates words ~text:new_text ~cursor ~limit:100 in
```

Replace the cached value and release it when the buffer closes. Both the index
and text snapshots are immutable. An index queried with a different physical
snapshot returns no candidates; `update` binds it to the new snapshot even for
identity-only changes. Updating the identical snapshot returns the same index.

## Work and storage

- Creation tokenizes the entire document; there is no 64 KiB cutoff. Words use
  `Search_match.small_word_class` identifier rules, with UTF-8 byte boundaries.
- A persistent lexical map stores one count per distinct word, rather than all
  occurrence offsets. Storage is O(distinct word bytes + distinct word count),
  plus one retained current text snapshot. Duplicate occurrences need no offsets
  and unchanged words need no shifting after insertion/deletion.
- `Text_buffer.changed_range` uses at most 64 replacement descriptors per
  snapshot, in either forward or reverse ancestry direction. These contain only
  identity tokens and offsets/lengths: **no ancestor snapshots or strings**.
  Identity-only snapshots share text identity. Metadata storage is bounded at
  approximately 5 KiB per snapshot and is included in `retained_bytes`.
- An update subtracts words in the old affected interval and adds words in the
  new interval, expanding to complete identifiers at both ends. Work is
  O(affected bytes + affected word occurrences × log distinct words), ignoring
  the cost of string-key comparisons. Creation has the same bound over the whole
  buffer. Ordinary local updates neither compare nor tokenize unchanged file
  prefixes/suffixes.
- A query seeks to the prefix in the lexical map, reads matching entries lazily,
  and stops at the requested limit. Ordering is case-sensitive byte-lexical,
  independent of proximity. Exact prefix words and the sole occurrence of the
  word currently being typed are omitted, including queries within a word.
  Empty prefixes enumerate the first lexical words up to the limit, with the
  same current-occurrence exclusion. The UI's automatic threshold controls
  suppression; manual Ctrl-n can request suggestions at an empty slot.

## Limits and worst cases

- The existing 4096-byte typed-prefix limit remains. Candidate count is bounded
  by the caller's limit (the screen uses 100). Word lengths
  are capped at 4096 bytes; longer identifiers are omitted. Vocabulary size
  remains unbounded; storage grows with the distinct vocabulary.
- An edit inside a very long identifier rescans that complete identifier. A
  query within an identifier inspects its suffix to identify the current word.
- Multiple skipped edits use a conservative contiguous enclosing interval, so
  distant edits can include substantial unchanged text in the tokenized region.
- Unrelated/branched snapshots or an ancestry gap exceeding 64 edits fall back
  to an O(document bytes) common-prefix/suffix comparison. Only the resulting
  affected interval is tokenized. Independently loaded identical text reuses the
  word map after comparison.
- Legacy `create` is synchronous; interactive creation yields by a 16 KiB work
  budget that includes key copying/map work (small buffers first try one bounded
  synchronous step).
  `Text_buffer` still deliberately copies
  its flat document string when editing; the index removes additional whole-file
  scanning, not that existing edit-copy cost.

## Reproducible measurement

Run `dune exec -j6 completion/test/bench_buffer_words.exe`. This reports CPU
time, bytes tokenized, and live GC storage added by the index, excluding the
already-created text. It separately times creation, 100 consecutive middle-file
one-byte updates, and 1000 prefix queries. Update timings exclude text edits;
snapshots are prepared first. The consecutive insertions grow one local word,
so tokenized bytes average 110–122 per update rather than a constant two bytes.

Example development-build results on the implementation host:

| Document | Vocabulary | Create | Index storage | Update average | Query average |
| --- | --- | ---: | ---: | ---: | ---: |
| 128 KiB | repeated | 10.9 ms | 512 B | 4.80 µs | 0.22 µs |
| 128 KiB | distinct | 5.8 ms | 640 KiB | 5.37 µs | 3.78 µs |
| 1 MiB | repeated | 31.1 ms | 512 B | 4.96 µs | 0.22 µs |
| 1 MiB | distinct | 49.8 ms | 5 MiB | 6.06 µs | 3.92 µs |
| 4 MiB | repeated | 124.4 ms | 512 B | 5.05 µs | 0.22 µs |
| 4 MiB | distinct | 214.2 ms | 20 MiB | 6.40 µs | 3.99 µs |

All initial scans tokenized exactly the document byte length. The repeated-word
query returns one match; the distinct-word query returns 100. These are sample
CPU measurements, not latency guarantees: first creation on multi-megabyte
buffers can cause a visible pause, and a mostly unique vocabulary has materially
higher memory overhead. Local update work stays independent of document size.

Tests in `completion/test/test_buffer_words.ml` cover tail words beyond 64 KiB,
large local replacements/deletions, prefix ordering/case, duplicate removal,
Unicode merges/splits, stale snapshots, undo/redo, skipped edits, history overflow,
unrelated snapshots, long words crossing the former cap, and deterministic random
incremental-vs-fresh comparisons. `core/test_text_buffer_diff.ml` checks range
composition/reversal and that metadata does not retain ancestor text snapshots.
