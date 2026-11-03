# Distribution notices and source coverage

Ches declares MIT in `dune-project`/`ches.opam`. No new copyright statement or
license grant is inferred by this packaging tool. Existing repository notices
are copied under `licenses/repository/`; available installed opam package license
texts are copied under `licenses/opam/`. Additional local audit material, when
provided, is copied under `licenses/audit/` without changing its conclusions.

The executable statically incorporates a modified **GPLv3** tree-sitter-gas
grammar. Its GPL text, separate Tree-sitter header MIT notice, provenance and
modification/regeneration records accompany this package. The matching project
source archive includes `grammar.js`, `parser.c.gz`, headers, bindings and build
rules. GPL obligations for the combined binary, including complete corresponding
source, must be addressed; the project metadata's MIT declaration does not replace
these obligations or license the whole executable under MIT.

The vendored SystemVerilog grammar and libvterm notices and provenance are also
preserved. OCaml Tree-sitter grammars/runtime are statically supplied by the opam
tree-sitter package; see its asset record for previously unresolved upstream
notice/revision questions. No missing upstream license text is fabricated here.

`metadata/opam-inventory.json` records **all installed packages in the build
switch**, including build-only/unrelated packages, with versions, declared
licenses and source repository/homepage links as reported by local opam metadata.
It is a build-environment inventory, not a proven list of linked OCaml units or
an assurance that all required notices are present. Links alone are not a complete
corresponding-source delivery. Dependency archives explicitly supplied to the
packager appear under `sources/dependencies/` and are hashed in the manifest;
their completeness is not automatically established. No network fetch occurs.

The manifest deliberately records `complete_corresponding_source_verified: false`.
This development packaging mechanism does not establish redistribution clearance.
