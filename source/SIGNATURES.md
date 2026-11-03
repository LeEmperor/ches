# Signature help and OCaml companions: source contract

`Language_query.kind` adds `Signature_help of { automatic : bool; character :
string option; retrigger : bool }` and `Companion_files`. Replies add
`Signature_result of signature_help option` and `Companions of string list`.
These use the existing Query request/token/cursor and Query_result event.

`signature_help = { signatures : signature list; active_signature : int;
active_parameter : int option }`; `signature = { label : string;
documentation : content list; parameters : parameter list;
active_parameter : int option }`; `parameter = { label_start : int;
label_stop : int; documentation : content list }`.
Parameter ranges are zero-based, half-open **UTF-8 byte offsets in label**, never
document coordinates. Unresolvable/ambiguous labels use `-1, -1`; retain their
parameter slot but do not highlight it. Tuple offsets on the wire are UTF-16
even for UTF-8/UTF-32 documents; split surrogate/code-point boundaries are invalid.
Active signature defaults to zero; invalid active parameters default to zero
when parameters exist, otherwise None. Per-signature active_parameter overrides
the result-level active_parameter; UI should use the selected signature's value
first. Documentation preserves plaintext/markdown metadata.

UI may submit automatic update intent after every source edit: set character to
the inserted character (including whitespace), or None for other edits, and
retrigger=true only while help is active. Source uses advertised triggers only.
Inactive automatic intent without a matching trigger returns Signature_result
None without RPC. Active updates use ContentChange (3), isRetrigger=true;
advertised characters use TriggerCharacter (2). Manual uses Invoked (1), bypassing
the UI automatic toggle. UI must still validate cursor/mode/focus/token before
displaying; None clears help silently. Automatic failures clear silently too.

Signature queries share the existing one-per-document navigation query lane;
completion remains independent. Queries flush the newest didChange and use the
existing 10-second deadline, cancellation and snapshot ownership checks.

Companions require server experimental.handleSwitchImplIntf=true (also accepted
in the installed server's experimental.ocamllsp namespace). Request
ocamllsp/switchImplIntf with params [uri], without fallback or filename guessing.
Companions contains normalized absolute local paths, not URIs. Source does no
filesystem existence checks: screen verifies targets before navigating. Empty
lists are successful. Unsupported manual requests yield Failed.

## Bounds and evidence

At most 64 signatures, 256 parameters per signature, 64 KiB per label/documentation
string and 256 KiB total displayed signature text are accepted. Companion lists
are limited to 256 URIs, 16 KiB each, validated as local file URIs and stably
deduplicated. Invalid responses produce Failed for manual queries and None for
automatic signature queries. No dynamic registration is advertised.

`dune exec -j 6 source/bench/signatures_probe.exe` probes both installed built-in
servers through the production transport using disposable files. On 2026-11-03,
ocamllsp 1.19.0+ox2 advertised space/~/?/:/( triggers, UTF-8 document positions,
and experimental.ocamllsp.handleSwitchImplIntf=true. It returned
`f : int -> int -> int` with parameter ranges [4,7), [11,14), and an absent-on-disk
`a.mli` counterpart. Slang advertised neither signature help nor experimental
companions; production source rejected both manual intents locally.

Source evidence: installed ocaml-lsp-server.1.19.0+ox2 source's signature_help.ml,
ocaml_lsp_server.ml and req_switch_impl_intf.ml; Slang's src/ contains no signature
provider implementation (its protocol declarations alone do not enable one).
