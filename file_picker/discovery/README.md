# Headless file discovery

This provider is independent of diagnostics, screen rendering, and buffers. It is
not yet a live file picker and adds no keybinding.

## Scope and dependency

`Project_root.find` selects the **nearest** ancestor of the starting document's
directory containing either `.git` (file or directory) or `dune-project`. It uses
the canonical starting directory when available and otherwise the absolute
lexical directory. With no marker it returns that directory. The host should
retain this project root when activating other files in the same project; each
discovery request carries the root explicitly. `source/workspace_root.ml` and
diagnostic root policy are unchanged.

Install **ripgrep** and ensure `rg` is on `PATH`. Missing executables or inaccessible
working directories produce an actionable `Failed` snapshot. Launch uses Async's
process API, an argument vector, and an explicit working directory, never a shell:

```
rg --no-config --files --null --glob '!**/.git/**' -- .
```

Normal ripgrep ignore rules apply (`.gitignore`, `.ignore`, global ignores, etc.).
Untracked files are included. Hidden path components and `.git` metadata are
excluded; directory symlinks are not followed. User ripgrep configuration is
disabled so it cannot silently enable hidden files or symlink traversal. File
symlinks are left to ripgrep's normal policy; buffer identity is not resolved here.
Paths are NUL-delimited and raw bytes are preserved, including whitespace,
newlines, and invalid UTF-8. Snapshots sort/deduplicate by raw relative path bytes;
display text is separately escaped by `Model.Candidate`.

## Delivery and lifecycle

Use one `Provider.t` per host and call it from the Async scheduler:

1. `start ~root` returns immediately with a fresh run identity and `Loading`.
2. Poll with a small `max_batches` per input/render turn. No worker callbacks
   touch editor state. Snapshots transition through `Partial` to `Complete` or
   `Failed`; an empty completed snapshot is an empty project, not a failure.
3. Cancel on close, or start again on refresh/root change. Old delivery pipes are
   closed and cleared, and run/root identity is checked before installing data.
4. `finished run` acknowledges child reaping and descriptor closure. It does not
   mean the host has polled the terminal snapshot. Starts wait for prior cleanup,
   even after explicit cancellation, so a provider has at most one subprocess.

Terminal-only polls preserve the candidate list identity, so installing completion
or failure does not restart already-published filtering. Cancellation retains the
bounded last snapshot/candidate map for inspection until refresh or provider
disposal; the host must separately close the interaction and drop old snapshots.

Selection remains owned by the pure model: preserve candidate identity when
installing incremental query results, not the old row number. Phase 3 supplies
matching; the phase-4 headless tile shows loading, errors, partial counts and
truncation.

## Resource policy

Defaults: at most 50,000 candidates, 4 KiB per emitted path, 8 MiB total candidate
string payload (root + absolute + relative + escaped display), and 32 MiB scanned
stdout. Roots are also limited to 4 KiB. Candidate map/set/list overhead is bounded
by the count limit; consumers must not keep every historical snapshot. A pending
delivery holds at most 128 candidates, plus one worker-local batch. Stderr is
drained concurrently in 4 KiB chunks with only an 8 KiB prefix retained; tool
errors are escaped before display. Workers yield between bounded record groups,
including duplicates/hidden paths, and stderr chunks.

Any path/count/payload/output cap terminates and reaps ripgrep and produces
`Complete { truncated = true }`. **The future UI must visibly disclose this**.
The retained subset follows ripgrep traversal order, so it is not promised to be
the lexicographically first subset; snapshots themselves always have deterministic
bytewise ordering. No `rg --sort` is used, since that would move unbounded file-list
storage into ripgrep. Refresh starts a new traversal; there is no persistent index.

A 30-second wall-time limit includes backpressure when a host stops polling.
Timeout produces `Failed` with any already-delivered/queued partial results;
cancellation produces `Cancelled` and drops queued results. Both forcibly terminate
the child and close streams, and `finished` waits for reaping. Exit codes 0 and 1
are normal completion; other exits or malformed NUL framing are failures that
retain valid partial candidates. Limits are configurable for tests/local policy;
these are safety bounds, not measured responsiveness claims.
