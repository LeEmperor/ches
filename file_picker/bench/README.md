# File query latency probe (phase 3)

Run sequentially using the documented toolchain:

```sh
rg --files --null --glob '!FILE_PICKER_PLAN.md' --glob '!file_picker/**' > /tmp/opencode/file-picker-paths.nul
opam exec --switch=5.2.0+ox -- dune exec file_picker/bench/query_latency.exe -- /tmp/opencode/file-picker-paths.nul > /tmp/opencode/file-picker-query.log
```

The optional first argument is a NUL-delimited list of normalized relative paths
(no `./` prefix). Without it the probe runs only synthetic fixtures. No traversal,
candidate construction, or field construction occurs in the query timing. The
synthetic fixtures have 1,000 / 10,000 / 50,000 distinct paths, cycling five source
directories and five basenames over numbered packages/components. Average path
length is 42.6 bytes; duplicate basenames are intentional. The largest set equals
the provider's default candidate-count cap, not its worst-case path-length cap.

Each mode/query gets one warmup followed by 10 monotonic-clock samples. GC runs
before, not inside, the sample loop; natural query GC is included. The executable
prints all raw samples, median (upper middle), maximum, matching count, total
allocated bytes per query, and one-time preparation/live-word delta. Counts and
ordered candidate identities are checked between uncached and cached modes.
Uncached uses `Fuzzy.rank` with the same loose policy/weights; cached uses
`Search.rank`, **including display-highlight mapping and result conversion**.
Consequently timings are conservative rather than identical workloads. Ten
samples are insufficient for p99 estimates; there is no timing pass/fail gate.

## Local observations, 2026-10-07

- Linux 7.0.0-34-generic, x86_64, AMD Ryzen 5 5600 (6 cores), local OxCaml
  `5.2.0+ox`, default Dune build profile, dirty working tree based on
  `a26e518721054aad05bdf66329176b097d4ec44f`. No CPU pinning or controlled power
  profile; other system activity is uncontrolled. Checks were not running during
  these measurements.
- Real input: 258 repository paths, 5,755 total bytes; NUL-list SHA-256
  `731ac16f646b9f4cfd6bd068c26f20795b373a6d4aae050200716b764920d535`.
- Raw before/after samples are in this session's
  `/tmp/opencode/file-picker-query-before.log` and
  `/tmp/opencode/file-picker-query-after.log` (temporary, not release artifacts).

Final cached query **median / max milliseconds**, including display mapping:

| Query | Real (258) | 1,000 | 10,000 | 50,000 |
| --- | ---: | ---: | ---: | ---: |
| empty | 0.004 / 0.006 | 0.017 / 0.018 | 0.176 / 0.479 | 2.120 / 3.344 |
| `m` | 0.086 / 0.121 | 0.411 / 0.442 | 6.478 / 7.932 | 34.987 / 40.412 |
| `model` | 0.022 / 0.027 | 0.323 / 0.459 | 4.317 / 4.831 | 24.855 / 27.792 |
| `src mod` | 0.049 / 0.056 | 0.422 / 0.476 | 4.494 / 4.641 | 25.527 / 27.208 |
| `sfp` | 0.042 / 0.095 | 0.173 / 0.186 | 2.230 / 3.009 | 15.058 / 15.716 |
| `zzzzzz` (none) | 0.019 / 0.020 | 0.101 / 0.104 | 1.062 / 1.226 | 9.616 / 9.887 |

At 50,000 paths: `m` matches all, `model` 10,000, `src mod` 4,000, `sfp`
6,000. Final uncached medians respectively are 106.488, 94.474, 101.769,
88.014 ms; no-match is 81.293 ms. Preparation is 0.336 / 1.713 / 30.085 /
153.501 ms at the four sizes. Retained prepared storage is approximately
0.29 / 1.56 / 15.61 / 78.05 MiB (live-word delta times 8), **in addition to
candidates, provider state, and current query results**. This is a memory tradeoff,
not part of the provider's 8 MiB string budget. Do not retain old prepared snapshots.

### Optimization evidence

Before feasibility prefiltering, cached medians at 50,000 paths were
63.042 ms for `model`, and 63.535 ms for no-match. This
justifies reusable decoding and skipping the dynamic-programming matrix when an
O(path length) scan proves there is no subsequence. Cached `model` allocation fell
from 265.0 MB to 66.0 MB/query; no-match from 293.0 MB to 4.8 MB/query. All-match
`m` still allocates 110.8 MB/query; its observed median moved from 31.847 to
34.987 ms, so prefiltering is not a universal speedup. It preserves scoring and
alignment, and exhaustive acceptance tests protect against false negatives.
The initial uncached prototype eagerly prepared the entire collection (190.606 ms
for `model`); the final uncached API retains the original one-candidate-at-a-time
preparation behavior. Do not treat that intermediate prototype as a pre-phase
command-palette baseline. Cached before/after workloads are unchanged apart from
the feasibility prefilter.

All matches are still scored and stably sorted. No top-result cap was introduced:
it would alter the full-result/selection contract, and should be decided with UI
counts, truncation semantics, and an agreed latency budget. Queries are synchronous;
50,000-path preparation and broad queries can exceed a frame budget. Worst-case
4 KiB paths, long queries, incremental rebuild frequency, live event scheduling,
and terminal responsiveness have **not** been measured here. This does not settle
ranking or meet an agreed responsiveness target. Obtain actual owner queries
and a target project before treating ranking/performance as release-ready.

## Phase-4 interaction/cache scheduling probe

```sh
opam exec --switch=5.2.0+ox -- dune exec file_picker/bench/interaction_latency.exe
```

The probe uses the same deterministic 1k/10k/50k synthetic paths, monotonic clocks
and local toolchain as above. It explicitly drains `Interaction.work` with budget
128, measures each turn (including natural GC), and asserts preparation count
stays exactly equal to candidate count across all queries. No discovery, candidate
construction, input routing, renderer, sleeps/yields or terminal redraw is timed.
These are **one run per query**, not warmed medians, p99 or time bounds.

Observed 2026-10-07, milliseconds **total explicit work / longest work turn**:

| Work | 1,000 | 10,000 | 50,000 |
| --- | ---: | ---: | ---: |
| initial preparation + empty publication | 4.416 / 0.713 | 43.481 / 2.902 | 234.507 / 3.951 |
| `m` | 0.853 / 0.120 | 11.890 / 0.458 | 74.196 / 0.741 |
| `model` | 0.763 / 0.098 | 11.777 / 0.702 | 69.399 / 1.654 |
| `src mod` | 1.593 / 0.322 | 12.918 / 0.398 | 72.085 / 0.624 |
| no-match `zzzzzz` | 0.512 / 0.076 | 8.369 / 0.320 | 52.218 / 0.599 |

Query update handlers measured 0.000–0.002 ms (tiny samples at clock resolution).
At 50k the initial and broad query need 782 turns; selective queries need
470 / 423 / 392. Scheduling one turn per 60 Hz redraw would be unacceptable;
phase 5 must actually schedule yielding work between redraws/input turns. Chunked
per-candidate matching and ordered inserts increase total CPU time versus phase
3's whole-list query; this buys explicit yielding/cancellation points, not a
matching speedup or top-result cap. Per-candidate tokenization and cache/map lookup
are included. No repeated full preparation occurs on a query or batch.

Post-initial-publication live-word delta is about 1.65 / 16.49 / 82.44 MiB,
excluding the already-constructed candidate dataset, versus phase 3's prepared
fields alone at 1.56 / 15.61 / 78.05 MiB. This is a rough retained-state estimate,
not peak RSS, in-flight-job peak, or a worst-case 4 KiB-path budget. It includes
prepared cache and empty-query results; intermediate cache/ranking/output maps,
old results and natural allocations require more memory. Future host scheduling,
long paths/queries, repeated incremental snapshots, GC tails, render scans and
actual input-to-screen response remain unmeasured.

## Phase-9 discovery probe

```sh
opam exec --switch=5.2.0+ox -- dune exec file_picker/bench/discovery_latency.exe -- "$PWD"
```

The argument is an explicit absolute directory. This measures provider start
through installed untruncated terminal snapshot and cleanup, including spawning rg,
traversal, candidate validation/escaping, delivery, sorting and polling. One
warmup precedes ten sequential monotonic samples; output gives all samples,
upper-middle median and maximum. Counts must agree between samples. The probe
polls one batch per turn and waits 1 ms while loading, so **poll cadence and
backpressure are part of these observations**. No ranking, terminal UI or rendering
is measured. Natural GC is included; caches are warm, OS/power/load uncontrolled.
This is not a p99 estimate or an editor latency gate.

Observed 2026-10-07 with rg 14.1.0, the same Linux/Ryzen/toolchain/default build
profile as above, dirty tree based on `a26e518721054aad05bdf66329176b097d4ec44f`:

| Dataset | Median / max ms | Raw samples ms |
| --- | --- | --- |
| Repository, 325 paths | 6.294 / 6.551 | 6.550, 6.551, 6.549, 6.419, 6.292, 6.294, 6.283, 6.287, 6.290, 6.289 |
| Generated source tree, 10k paths | 103.017 / 105.777 | 97.780, 103.017, 104.593, 99.875, 102.755, 102.763, 103.014, 105.777, 103.935, 104.331 |

Repository path bytes: 7,634; sorted relative paths with NUL terminators SHA-256
`57b8ab7258ae0ac419cfb137915a2b27afb81e931d720e09736b164744641e9d`.
This was measured before adding `docs/pickers.md`; future path counts will differ.
Synthetic path bytes: 426,000; manifest SHA-256
`51f85e687e0b2aedb1bf9a5c0080bca361b086ea531865faaa8498d7f6e46a77`.
Both runs completed without truncation. All generated files are empty; fixture
construction is outside timing. The temporary fixture was removed after the run.

Recreate the synthetic dataset and run the probe from the repository root:

```sh
python3 - <<'PY'
from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess
with TemporaryDirectory(prefix='picker-discovery-10k-', dir='/tmp/opencode') as directory:
    root = Path(directory)
    for i in range(10000):
        folder = ['src', 'test', 'lib', 'docs', 'vendor'][i % 5]
        name = ['model.ml', 'file_picker.ml', 'controller.ml', 'README.md', 'test_search.ml'][(i // 5) % 5]
        path = root / folder / f'package_{i // 25:04d}' / f'component_{i % 25:02d}' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch()
    subprocess.run(['opam', 'exec', '--switch=5.2.0+ox', '--', 'dune', 'exec',
                    'file_picker/bench/discovery_latency.exe', '--', str(root)], check=True)
PY
```

The parent temporary directory must exist. Fixture-root length participates in
the provider string budget, and these typical paths are not a worst-case 4 KiB
stress test. Historical query/line measurements above and in `line_picker/README.md`
remain headless observations, not newly remeasured live results. Agree an owner
dataset and responsiveness budget before making release performance claims.
