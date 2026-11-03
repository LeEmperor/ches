# OCaml-defined snippets and variable-backed fields

## User contract

```ocaml
open Ches_config

let () =
  Snippets.add
    ~id:"personal.module"
    ~prefix:"mymod"
    ~scope:[ "systemverilog" ]
    ~description:"Module named after the current file"
    {|module ${1:${TM_FILENAME_BASE:untitled}} (
    $0
);
endmodule|}
```

`Snippets.add ~id ~prefix ?scope ?description body` registers or overrides one
template. Omitted scope is global. `Snippets.disable ~id` removes an entry.
Declarations are applied in order, last declaration for an ID wins. Each fresh
config evaluation starts with no user operations. Invalid entries identify their
ID and reject the complete configuration: active settings/catalog remain intact.

Builtins remain available. Existing optional `snippets.json` is supported as a
legacy base layer, with OCaml declarations applied last. Async legacy loading must
never replace OCaml overrides. Reload configuration atomically replaces settings
and OCaml declarations, restoring base entries when overrides are removed.

## Variable-backed defaults

Numbered placeholder defaults may contain supported filename variables and their
literal fallbacks, e.g. `${1:${TM_FILENAME_BASE}}`. Resolution happens before
installation; the resulting default is selected/editable and mirrors stay linked.
Arbitrary nested numbered placeholders, nested choices, and transforms remain
unsupported. Parsing remains bounded, paths are literal, and indentation is
applied exactly once after resolution.

## Ownership and verification

- Config/provider worker: standalone API, versioned helper result protocol,
  settings operations, pure catalog operation application and tests.
- Integration worker: atomic screen/UI configuration and legacy layering, tests.
- Syntax worker: parser/default representation and local/LSP/session tests.
- Manager: docs and migration of personal header snippets after validation.

Check real compiled OCaml declarations, body strings with newlines/escapes, invalid
entry rejection, reload rollback, legacy result races, remove/disable overrides,
filename-backed fields/mirrors/choices/indentation, and full regression suite.
No Git mutations; three workers max, six jobs each. Personal config migration
preserves the original JSON as an inactive backup and retains all existing settings.

## Status

Implemented and validated. The Stdlib-only API records ordered operations, encoded
in bounded `CHES_SETTINGS_2` output. The host validates every declaration using the
same provider/parser rules as local templates. `Settings.snippets` defaults to an
empty operation list. Catalog application is immutable and settings/theme/catalog
validation completes before any live mutation. Separate legacy-base and OCaml
operation state preserves precedence across asynchronous legacy loads and reloads.

Numbered defaults now retain literal/variable segments through resolution, keeping
filename-backed fields editable and mirrored. Parsing rejects arbitrary nested
fields/choices, transforms and recursive variable fallbacks. Unicode paths are
inserted literally and indentation applies exactly once. The bundled `mod` uses
`${1:${TM_FILENAME_BASE:module_name}}`.

Full `dune build -j 12 @all` and `dune runtest -j 12` passed. Review found no further
production defects and added missing-config reset and atomic multi-setting rollback
regressions. Follow-up completion/screen suites passed after updating `mod`.

The personal configuration retained all settings and gained both header templates.
`dune exec -j 6 config/test/check_config.exe -- /home/wayne/.config/ches/config.ml`
reported `Configuration valid: 2 snippet operations`. The original JSON was moved
unchanged to `~/.config/ches/snippets.json.migrated` after successful validation.
No Git staging, commits, or pushes were performed.
