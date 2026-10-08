# Tree-sitter highlight assets

`ches_highlight_tree_sitter` links the **existing pinned `tree-sitter.0.1.0` opam
package** (`tree-sitter` and `tree-sitter.ocaml` Dune libraries). Its C runtime and
implementation/interface grammars are compiled into the executable. Ches does not
vendor the OCaml grammars, regenerate them, fetch them at runtime, or search a
development path. The shared provider also supports a vendored SystemVerilog grammar;
see [grammar/ASSETS.md](grammar/ASSETS.md) for its pin, checksums, and license.
AT&T/GAS assembly uses a separately vendored, locally patched **GPLv3** grammar;
see [gas_grammar/ASSETS.md](gas_grammar/ASSETS.md) for its source, checksums,
regeneration recipe, notices and distribution implications. This is not an MIT/ISC
grammar, and its license does not replace the license of existing Ches code.
No Tree-sitter CLI, Node, or external editor installation is required.

Package release: Mosaic commit `bbaec9a2b49eccc7be958df1a3fc3f53443787b8`.
Archive SHA-256:
`9e4e90d17f9b2af1b07071fe425bc2c519c849c4f1d1ab73cde512be2d874849`.
The bundled generated parsers both use language ABI 15. Grammar blobs recorded
in the feasibility investigation:

- Implementation: `67724008e33a04ac9585947e2ec9b7db82741f3c`.
- Interface: `7866e97b42e8324687981cb685ff42e1ab04e70e`.

`ocaml_queries.ml` contains **Ches-authored, predicate-free structural queries**, based
on grammar symbol/field inspection and the phase 0 probe. No upstream highlight
query file was copied. Both OCaml grammars compile the shared OCaml query independently when
a provider is created. The OCaml configuration key is
`tree-sitter.0.1.0/ches-ocaml-structural-v1`; bump its query version when changing
highlight behavior. Normalization uses `ches_highlight.Snapshot`'s overlap policy,
not query order. Function recognition is structural, not name resolution: bindings
with parameters or a direct `fun`/`function` body, simple calls, and arrow-typed
value/external specifications. Other value occurrences remain variables.

## License/provenance record

The OCaml binding is **ISC**, copyright 2025 Thibaut Mattio. Upstream Tree-sitter
runtime and tree-sitter-ocaml grammar projects are **MIT**; Tree-sitter also ships
a separate Unicode license notice. **The exact upstream runtime and generated
grammar revisions bundled by Mosaic have not been established.** The installed
package's inspected notices contained the binding ISC text, but not the separate
runtime/grammar/Unicode notices. Do not label the complete C bundle ISC or assume
the parsers match upstream OCaml `v0.26.0`.

The owner declined further investigation; this unresolved audit is not an
implementation gate. That disposition is **not a finding of license compliance**.
No additional audit or source vendoring was performed in phase 3. See
[`syntax_highlighting_plan.md`](../docs/archive/syntax_highlighting_plan.md) for the earlier findings and disposition.

## Ownership and limitations

One provider owns its parser and compiled query; callers must serialize use.
`Provider.highlight` resets and freshly parses the full source as a reference.
`Provider.highlight_incremental` retains one successful source/tree privately,
derives a UTF-8-safe encompassing replacement, copies/edits the prior tree and
parses with it. New document identities parse fresh; controller reload/language
changes recreate the session. All calls query and normalize the complete tree.
No native tree/node escapes into snapshots or editor history; cursors are local.
`Provider.close` drops source/tree/parser/query references; native destruction relies on the binding's GC
finalizers, because it exposes no explicit delete for those objects. Production
code does not force GC. Earlier probe measurements showed substantial retained
RSS; a provider lifetime does not promise prompt native-memory reclamation.

Syntax-error trees are normal input. Initialization and binding failures produce
an empty snapshot for the requested key plus a failure status. Failed sessions
are disabled until recreated; no stale highlights, retries, logging, or editor
messages are produced internally. Invalid UTF-8 and byte lengths above uint32
are rejected before parsing. Process-fatal exceptions are not hidden.

Reproduce provider tests and a bounded Linux resource observation with:

```sh
opam exec --switch=5.2.0+ox -- dune runtest highlight_tree_sitter/test --force
opam exec --switch=5.2.0+ox -- dune exec ./scripts/syntax_provider_probe/probe.exe
```

The standalone probe runs 200 calls per grammar on a generated 500-copy fixture
with one reused provider, checks deterministic normalized ranges, and prints
whole-call timing and RSS after forced collection. It is not part of `dune runtest`
or the editor. It does not prove arbitrary-file scalability or prompt native
disposal. Phase 5's separate probe compares fresh/incremental CPU costs for
preparation (diff/copy/edit), parsing, full query/capture extraction, normalization,
and cached frame rendering on 10/1,000/5,000-copy `.ml`/`.mli` fixtures:

```sh
opam exec --switch=5.2.0+ox -- dune exec ./scripts/syntax_incremental_probe/probe.exe
opam exec --switch=5.2.0+ox -- dune exec ./scripts/syntax_live_probe/probe.exe
```

These explicit probes are not editor work. Full-source UTF-8 checks, snapshot diff,
whole-string editing, querying and normalization remain; large-file typing can
still lag. See the plan handoff for measured results and unchecked memory risks.
