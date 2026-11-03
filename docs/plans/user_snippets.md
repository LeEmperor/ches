# Independent user snippets

## Goal and interaction

Supply reusable templates independently of the language server. Candidates use
the existing prefix filtering, Tab cycling and Enter-to-placeholder handoff, with
a `[snippet]` source tag. Automatic and Ctrl-n invocation both include them.

## Configuration contract

Use `$XDG_CONFIG_HOME/ches/snippets.json` when the environment variable is an
absolute nonempty path; otherwise `$HOME/.config/ches/snippets.json`.

```json
{
  "version": 1,
  "snippets": [
    {
      "id": "sv.aff",
      "prefix": "aff",
      "scope": ["systemverilog"],
      "description": "Clocked always block",
      "body": ["always_ff @(posedge ${1:clk}) begin", "    $0", "end"]
    }
  ]
}
```

Body accepts a string or an array of lines. Omitted/empty scope means global.
Scopes use language identifiers (systemverilog, verilog, ocaml) or filename
extensions beginning with a dot. A matching user ID overrides a bundled starter;
`{"id":"sv.aff","disabled":true}` disables it. Duplicate user IDs and malformed
entries report actionable errors; invalid reloads preserve the last good catalog.
The parser supports the existing bounded snippet syntax only.

## Delivery boundaries

1. Pure `completion/User_snippets`: configuration parsing, starter collection,
   scope matching, indentation, and candidate generation. Extend candidate sources
   with `Snippet`; do not deduplicate a real template away against a plain word.
2. Screen/input/palette: catalog ownership, candidate merging, `[snippet]` rendering,
   Reload snippets command, pure load request/result boundary with generation
   rejection, failure feedback. No disk reads in render/input transitions.
3. UI runtime: bounded asynchronous config loading on startup and explicit reload;
   missing config uses bundled starters; no directory or config creation. Tests for
   path selection, failures, size limits and stale loads.

Template indentation preserves relative body indentation and prefixes subsequent
lines with the insertion line's leading whitespace. Reparse after indentation so
placeholder offsets are correct. Candidate primary ranges replace only the typed
prefix; additional edits are empty and no LSP resolve is needed.

## Verification and policy

Scope/override/malformed input/indentation tests; source-free screen workflows,
cycling and linked fields, reload/error retention; asynchronous host tests; full
build and relevant suites. Three agents at most, six jobs each, global cap 20.
No git staging/commits/pushes. No modification of personal config files.

## Status

Implemented and validated. Bundled SystemVerilog starters are available without
configuration or LSP. User templates override/disable by ID, and global or scoped
templates merge through the existing completion model with a distinct source and
placeholder-aware deduplication. Local templates rank before other sources.

The pure implementation lives in `completion/user_snippets.ml`; screen and runtime
boundaries are documented in `screen/USER_SNIPPETS.md` and `ui/USER_SNIPPETS.md`.
The host keeps one active and one latest pending load, bounds file reads, and runs
reading/parsing on a worker thread. Screen generation checks reject stale loads.
Failed parses/reads retain the last good catalog; missing files restore starters.

Review found no production correctness defects and added regressions for escaped
multiline linked defaults, builtin/LSP coexistence in either reply order, invalid
partial catalogs/duplicate disables retaining the last good entry, and proving
keystrokes do not trigger configuration reads.

Passed `dune build -j 12 @all` and `dune runtest -j 12`. Review regression suites
passed with `dune runtest -j6 completion/test screen/test ui/picker_test`, plus
`git diff --check`. User configuration files were not modified. Usage and editable
starters are in `docs/editor_reference.md` and `docs/snippets.example.json`.
