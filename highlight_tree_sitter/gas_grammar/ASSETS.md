# AT&T/GAS grammar assets

Source: [sirius94/tree-sitter-gas](https://github.com/sirius94/tree-sitter-gas),
commit **`60f443646b20edee3b7bf18f3a4fb91dc214259a`**.
Archive: <https://codeload.github.com/sirius94/tree-sitter-gas/tar.gz/60f443646b20edee3b7bf18f3a4fb91dc214259a>.
There is no external scanner. The generated parser uses **language ABI 14**,
supported by the installed `tree-sitter.0.1.0` binding/runtime. No runtime fetch,
Node installation, external query file or Tree-sitter CLI is needed by Ches.
Builds expand `parser.c.gz` with gzip and compile the parser and the Ches-authored
C/OCaml binding, following the SystemVerilog grammar library pattern.

## License and modifications

Upstream ships the **GNU GPL version 3** in `LICENSE`, preserved verbatim here.
Treat the upstream grammar and its generated parser, including these local grammar
changes, as GPLv3 assets; do not label them MIT or ISC. No separate upstream author
copyright notice or explicit "or later" grant was found in the inspected grammar,
README or package metadata. The FSF copyright in `LICENSE` covers the license text,
not authorship of this grammar. The generated `tree_sitter/parser.h` comes from
Tree-sitter CLI v0.22.6; its MIT notice is preserved in `LICENSE.tree-sitter`.

The GAS parser is statically linked into Ches. Distribution of a combined binary
must account for GPLv3 requirements, including applicable corresponding-source
and license-notice obligations and compatibility of the combined work. This asset
record does **not** relicense existing Ches-authored code, overwrite its notices,
or establish compliance of the complete executable or its other dependencies.

Local grammar patch version **`ches-gas-grammar-v2`** (2026-10-08):

- Numeric label definitions and `Nb`/`Nf` references, including directive expressions
  such as `.long 1f - 0f`.
- Single-atom expressions for assignments (`foo = 1`) and directive arguments.
- Immediate arithmetic (`$foo+8`) and operand/displacement arithmetic
  (`foo+8(%rip)`), preserving numbers, symbols and relocation-modifier nodes.
- Whitespace-separated `.file` and `.loc` debug arguments: numbered filenames,
  directory/filename pairs, optional metadata and location options (including
  `view -0` and symbolic views), tabs, trailing whitespace/comments and CRLF.
  These directives use separate number/string/symbol atoms, not expressions.
  Other directives retain comma-separated expression lists: a generic whitespace
  separator would ambiguously split `.long 1f - 0f` and `foo -8` arithmetic.

`grammar.js` is the patched source, retained for regeneration. The expression
tree is for highlighting, not evaluation or assembler-semantic validation.
`../gas_queries.ml` is Ches-authored and predicate-free; no upstream query was
copied. Directives/mnemonics/prefixes are Keyword, registers Constant, labels and
local references Function, symbols Variable, literals Number/String, and relocation
modifiers/directive types Property. Snapshot normalization prefers narrower spans
first, then category priority, not query order. Queries capture immediate contents
directly and do not split the `@` from directive types.

Provider configuration:
`tree-sitter-gas.60f44364/ches-gas-grammar-v2/ches-gas-structural-v1`.
Bump the grammar/query version when changing the respective behavior.

## Checksums (SHA-256)

Original upstream assets:

| Asset | SHA-256 |
| --- | --- |
| Archive | `413a2114c0ad31bd09762be051c6351b67df38bc6f5625f835e8253a2d1cf477` |
| `grammar.js` | `3f354bf075cd12eae3f5aa23fcf01f767610b0ef30ee28d06bdb60fc1af78081` |
| `src/parser.c` | `be7560454a54049f9c0c92242a57a1e4016f46479e8d482c7438822b32da2297` |
| `src/tree_sitter/parser.h` | `ab104936984904469572a4e868149f7a22fb2929347f837ae6a1f9b790f1b173` |
| `src/node-types.json` | `7967380f38834fb59b3c2f776aa941c30c601a4a1e5f80fead8f9efae30f73ec` |
| `LICENSE` (also bundled unchanged) | `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986` |

Patched/regenerated bundled assets:

| Asset | SHA-256 |
| --- | --- |
| `grammar.js` | `0311687cf80e8a06689d794c79f7e2a8bc6c95e06fffd1400d5588b60bcffd3e` |
| Expanded `parser.c` | `638e5e1dfb0d3bbeb8bdd0075f52f0c9a101e41423eaf7c8495c9e3d92a95428` |
| `parser.c.gz` | `e5ab600dd16ad65f60cd0c6dd7178790d779f20523a8248c57b21a4bef70f032` |
| `tree_sitter/parser.h` | `a3eb18ef034b3f4255b965a26caa276f9cfe13a79573b402f1a12dc5018052aa` |
| `node-types.json` | `17f68708eb368d56e68f87eeb6076a35e1e9e4485e1c3b4bec5f085b6196c3be` |
| `LICENSE.tree-sitter` | `5f9cf9fb6acb1972b35ae29119ce563bb60ec097656bc4b69b9bac2d04c7a147` |

## Reproducing generation

Generation used **tree-sitter-cli 0.22.6**
(`b40f342067a89cd6331bf4c27407588320f3c263`), Node 18.19.1, npm 9.2.0 and
Python 3.12.3. From the repository root, install the development-only generator
in a temporary directory, then generate from the retained patched grammar:

```sh
opam exec --switch=5.2.0+ox -- npm install --prefix /tmp/opencode/gas-tools tree-sitter-cli@0.22.6
mkdir -p /tmp/opencode/gas-regenerate
cp highlight_tree_sitter/gas_grammar/grammar.js /tmp/opencode/gas-regenerate/grammar.js
opam exec --switch=5.2.0+ox -- sh -c 'cd /tmp/opencode/gas-regenerate && /tmp/opencode/gas-tools/node_modules/.bin/tree-sitter generate --abi 14'
opam exec --switch=5.2.0+ox -- python3 - <<'PY'
from pathlib import Path
import gzip, shutil
src = Path('/tmp/opencode/gas-regenerate/src')
dst = Path('highlight_tree_sitter/gas_grammar')
(dst / 'parser.c.gz').write_bytes(gzip.compress((src / 'parser.c').read_bytes(), mtime=0))
shutil.copyfile(src / 'node-types.json', dst / 'node-types.json')
shutil.copyfile(src / 'tree_sitter/parser.h', dst / 'tree_sitter/parser.h')
PY
```

The gzip timestamp is zero; byte-identical gzip output also depends on the
Python/zlib version. Compare the expanded parser checksum independently.
CLI-generated language-package scaffolding and unused headers stay in the temporary
directory and are not vendored. The upstream archive is needed only to inspect the
original source or compare the patch; it is not an input to normal builds.

## Tests and limitations

```sh
opam exec --switch=5.2.0+ox -- dune build
opam exec --switch=5.2.0+ox -- dune runtest --force
```

Tests cover compiler-like and debug-directive fixtures, numeric labels/references,
expressions and assignments, normalized categories, subsequent instruction captures,
binary subtraction versus signed debug atoms, error recovery, incremental/fresh
equality, snapshot immutability, `.s`/`.S` detection, `.asm` exclusion and rendered
edit/undo. Debug directives are also checked independently at EOF.

On 2026-10-08, actual `cc -g -O0 -S` and `cc -g -O2 -S` output from GCC
13.3.0 (Ubuntu `13.3.0-6ubuntu2~24.04.1`) was verified with the regenerated ABI-14
grammar through the installed `tree-sitter.0.1.0` OCaml binding. The C input had
an external call/global, a conditional and an array-summing loop. Both trees were
error-free: O0 had 3 `.file`, 16 `.loc` and 39 instruction-name nodes; O2 had
3 `.file`, 28 `.loc` and 23 instruction-name nodes. Instruction counts matched
all instruction lines in each assembly file, including those following `.loc`.
This is a compiler-output spot check, not a guarantee for all compilers/targets.

The grammar is mostly x86 AT&T syntax, not Intel syntax or an assembler validator.
It accepts arbitrary mnemonic/register names. Known unsupported or partially
supported forms include x87 `%st(0)`, AVX-512 decorators, relocation modifiers in
directive arguments, multiple labels on one line and `rep; ret`. Whitespace-only
argument lists are supported for `.file` and `.loc`, not arbitrary directives;
their option names/counts are not assembler-semantically validated, and arithmetic
debug arguments are not supported. `.S` C-preprocessor lines are comments, not
parsed preprocessing.
Upstream treats multiline comments as whitespace rather than GAS's line feed.
Malformed/unsupported forms recover useful captures without promising a clean tree.
The provider's synchronous full-query/normalization and native-memory limitations
in [../ASSETS.md](../ASSETS.md) apply equally to GAS.
