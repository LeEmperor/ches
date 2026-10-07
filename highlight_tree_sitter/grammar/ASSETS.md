# SystemVerilog grammar assets

Upstream: <https://github.com/gmlarumbe/tree-sitter-systemverilog>

Pinned commit: `d6be6119fe4d04c65c567e7b79625aa6280fea34` (2026-09-29).
Language ABI: **15**, supported by the existing pinned `tree-sitter.0.1.0` runtime.
Grammar entrypoint: `tree_sitter_systemverilog`; no external scanner is required.
The same grammar serves `.sv`, `.svh`, `.v`, and `.vh` files.

Vendored verbatim from that commit:

- `src/parser.c`, stored as `parser.c.gz` (gzip with timestamp 0).
- `src/tree_sitter/parser.h`, stored under `tree_sitter/`.
- `src/node-types.json`, for maintaining structural queries.
- `LICENSE`: MIT, copyright 2024–2025 Gonzalo M. Larumbe.

SHA-256 of the uncompressed generated parser:
`f96c55cb0996371f7d7abfbff230d87b583fa89314912806d7407eedbc27eb61`.
SHA-256 of the downloaded GitHub source archive:
`2e5197cb0adcd32911eeaff6deeb05306f9de52d3cbc1066e5d587e718a9758d`.
Archive URL:
<https://codeload.github.com/gmlarumbe/tree-sitter-systemverilog/tar.gz/d6be6119fe4d04c65c567e7b79625aa6280fea34>

Dune expands the roughly 2.6 MB compressed source to roughly 64 MB of generated C
using `gzip`, then compiles and links it into Ches with `binding.c`. Rebuilding the
grammar can take longer than rebuilding OCaml code. The OCaml wrapper constructs
`Tree_sitter.Language.t` from that static grammar pointer; it cannot outlive the
grammar. No runtime file search, download, CLI, Node, or grammar regeneration is
required. There is only one Tree-sitter runtime, supplied by the opam package.

`../systemverilog_queries.ml` contains Ches-authored structural queries using the
pinned grammar's node types and fields. No upstream editor query was copied. Queries
have no predicates, matching the OCaml binding's capabilities. The provider shares
incremental parsing, UTF-8 validation, immutable snapshots, and failure handling
with OCaml. Its freshness configuration is
`tree-sitter-systemverilog.d6be6119/ches-sv-structural-v1`; bump this when changing
the grammar or queries.

Highlighting is grammatical rather than semantic. The query recognizes declarations,
built-in types, literals, comments, preprocessor tokens, and operators. It does not
resolve cross-file types, expand includes/macros, or use slang-server's compilation
configuration. Incomplete headers and malformed code are normal editing input.

To update, download a specific upstream commit, replace the generated parser/header,
node types and license, record new checksums and ABI, and update the provider key.
Compress the verbatim parser with `gzip -n -9`. Run `dune build` and `dune runtest`,
including the SystemVerilog category, incremental/fresh comparison, and live editor
rendering tests before accepting a new grammar.
