# Terminal backend

Public libraries:

- `ches_terminal`, wrapped `Ches_terminal`, exposes `Model` (no Async dependency).
- `ches_terminal_host`, wrapped `Ches_terminal_host`, exposes `Runtime`.
- `ches_terminal_emulator` contains the libvterm adapter, independently testable
  without a shell or scheduler. Frontends only need the first two libraries.

`Model.mli` and `host/runtime.mli` define the frontend contract. Submit `Start`
with the workspace directory and terminal dimensions, then consume `next_event`.
Asynchronous frontends should consume `next_event_with_generation` instead and
reject updates from older sessions after restart. The screen model's
`Terminal_update` input implements this check.
Submit keys with their original modifiers; `Char` carries the actual Unicode
character. Submit clipboard text using `Paste`, never a sequence of key events.
Snapshots are independent, own their cell arrays, and use zero-based coordinates.
Wide continuation cells have width zero. Default colors remain symbolic rather
than being replaced by a hard-coded palette.

## Session lifecycle

A host owns one interactive shell, using an absolute `$SHELL` or `/bin/sh`, with
an exec-failure fallback to `/bin/sh`. The child receives `TERM=xterm-256color`.
The C-only `forkpty`/`execve` path creates a new session and real controlling
terminal; OCaml never executes in the child. Inherited signal dispositions and
masks are reset, and nonstandard descriptors are closed before exec.

The frontend's `ui/terminal_host.ml` pools these single-shell runtimes by terminal
number. It launches them lazily, drains hidden sessions independently, coalesces
events per number, delivers ready sessions fairly, and shuts down the entire pool
on editor exit. Generation checks are local to each numbered terminal.

The nonblocking PTY master is close-on-exec. The Async pump runs independently of
UI visibility, with a 10 ms interval and a 64 KiB per-direction work budget per
turn. It handles short writes, EAGAIN, EINTR, Linux EIO-as-EOF, protocol replies,
window-size changes, foreground job-control interrupts, and child reaping. Raw
output only enters libvterm; nothing is forwarded to the outer terminal.

The screen supports libvterm's alternate screen and UTF-8 handling. Keyboard
encoding uses the emulator's current cursor/newline modes and modifier handling;
paste uses the current bracketed-paste mode. There is no scrollback allocation.
The CLI disables outer-terminal CR/LF input translation so physical Enter (CR)
stays distinct from Ctrl-J (LF). The frontend reverses Notty's LF-as-Enter naming
when forwarding terminal input, allowing Ctrl-J to insert newlines in OpenCode.

Events occupy a two-slot mailbox: latest snapshot and latest failure. Input
waiting to be written is limited to 1 MiB, as are individual pastes and generated
protocol replies. Oversized input reports `Failed`. Dimensions must be positive,
at most 500 rows / 1000 columns, and at most 250,000 cells. Invalid requests
report `Failed` without raising through `submit`.
An input rejection is nonfatal: it does not stop a live shell. Input within each
submitted batch is staged atomically so a rejected paste cannot leave a partial
prefix or trailing Enter queued from that batch.

On exit, the final screen and exit status are published. `Start` while a shell
is live is ignored; after its exit event, `Start` creates a fresh session and
clears pending old events. `Stop` requests SIGHUP of the shell and foreground
job. After 250 ms, shutdown escalates to SIGKILL. Remaining members of the Linux
PTY session, including background job groups, are killed when the shell exits.
`shutdown` is idempotent, rejects further submissions, and resolves after the
child is reaped and the PTY/emulator are closed. An idle `next_event` remains a
wait for an event; callers should stop their consumer when their host shuts down.

## Vendor and checks

libvterm 0.3.3 is compiled from the pinned source release under
`libvterm-0.3.3/`; see `VENDOR.md` for the URL, archive digest, and MIT license.
No system libvterm or additional OCaml package is needed. Linux linking uses
`libutil` for `forkpty`.

Run only the backend tests:

```sh
dune runtest -j 6 terminal/test
```

The emulator tests cover screen editing, scrolling, alternate screens, styles,
split Unicode, cursor visibility, mode-aware keys/paste, protocol replies, resize,
immutable snapshots and GC roots. Runtime tests use a real interactive `/bin/sh`
and check controlling-terminal access, cwd/environment, persistent shell state,
PTY resize, hidden output flood/coalescing, Ctrl-C, 128 KiB partial input writes,
input bounds, child exit, restart, forced shutdown, invalid setup, and shell
fallback. The runtime fixtures require standard Linux `stty`, `sleep`, and GNU
`dd` utilities.
