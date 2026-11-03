# Signature help, OCaml companions, and configuration caching

## Scope

1. Capability-aware standard signature help. Manual Ctrl-k in the file editor and
   a Signature help palette action; automatic help defaults on, with a palette
   toggle and `Signature_help.set_enabled` in config.ml. The server's trigger and
   retrigger rules determine automatic requests; current arguments are highlighted
   from server metadata, not editor-side language parsing. Overloads have explicit
   cycling controls that do not interfere with snippets/completion. Unsupported
   automatic requests are silent, manual requests explain unavailability.
2. Switch interface/implementation palette command for advertised ocamllsp
   `handleSwitchImplIntf`. This switches companion files, not symbol definitions.
   Existing buffers are reused; multiple counterparts use a picker, missing files
   report a notice without automatically creating them. Successful switches enter
   jump history.
3. Cache compiled configuration helpers, never evaluated settings. Every startup
   and reload still executes config.ml. Cache identity includes source and source
   path, embedded API/writer/protocol and compiler identity. Corrupt/missing cache
   entries recover by recompilation; unavailable/unwritable cache falls back to
   private temporary compilation. Runtime failures are not retried and never apply
   partial configuration. No personal config changes or saved runtime preferences.

## Evidence and boundaries

The inspected ocamllsp implements signature help with space/~/?/:/( triggers.
The Slang checkout has no signature-help provider; do not claim SV support absent
capabilities. Companion parameters are a one-element URI array, not a document
position object. Inspect actual installed capabilities through lightweight probes.

- Source/error worker: typed signature/companion requests/results, trigger filtering,
  metadata normalization, async bounds, tests and probes.
- Screen/UI worker: signature state/render/input, companion navigation, config
  setting consumption and frontend lifecycle.
- Config worker: compiled cache, standalone Signature_help setter/default/snapshot
  field and protocol extension, cache invalidation/failure/concurrency tests.

Signature parameter offset tuples are UTF-16 offsets within the signature label
regardless of document position encoding. Convert exactly before highlighting.
Responses must match live document/cursor/mode/focus; context selection, reload,
paste/snippet activation, edits and server restart invalidate old help.

## Validation and policy

Scripted servers and UI tests for signatures/overloads/trigger behavior, stale
replies, Unicode labels, unsupported servers, and companion files/history. Config
tests verify actual compile reuse with fresh execution/environment and invalidation.
Full regression suite after review. Three workers, six jobs each, cap20 total;
no Git staging/commits/pushes or personal config changes.

## Status

Implemented and validated. Signature help has manual Ctrl-k invocation and an
automatic session toggle/config setter. The non-focusing overlay highlights byte
ranges normalized from UTF-16 parameter offsets, supports overload cycling with
Insert Ctrl-g/Ctrl-b, and shares space with completion without stealing its keys.
Source handles advertised trigger filtering; unsupported automatic help is silent.
Companion switching uses the advertised custom capability, preserves existing
counterpart buffers/cursors, and uses normal picker/history validation.

Installed ocamllsp returned `f : int -> int -> int` and an absent-on-disk `a.mli`
counterpart. Its capability is nested under experimental.ocamllsp. Installed Slang
advertised neither feature; no unsupported requests were sent. Production transport
probe: `dune exec -j 6 source/bench/signatures_probe.exe`.

The config cache stores compiled helpers under the XDG/HOME cache directory, with
source/API/protocol/toolchain/environment identity and artifact checks. Every load
executes in a new private directory with a runtime result path. Missing/corrupt
cache compiles before execution; runtime errors never retry the config. Publication
and pruning are locked, bounded and limited to owned recognized entries. External
preprocessor/dependency flags use ephemeral compilation. A local review sample
measured 88.74 ms cold and 47.89 ms warm; timings are not guarantees.

Review fixed Normal Ctrl-k keymap bypass, completion-lane starvation of signature
queries, overload fallback highlighting, concurrent cache-reader/pruner races,
unrelated-file deletion risks, unbounded cache inspection and stale external
preprocessor reuse. Tests also verify fresh runtime settings/snippets/environment,
no double execution on errors, cache corruption and compiler invalidation,
counterpart failures and signature stale-context handling.

Final `dune build -j 12 @all`, `dune runtest -j 12`, and `git diff --check` passed.
All work stayed within the 20-job aggregate limit. No user configuration changes,
Git staging, commits, or pushes were performed.
