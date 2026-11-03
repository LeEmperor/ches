# Executable OCaml configuration

## User model

Each startup/reload creates complete supported defaults, executes the user's
`config.ml`, validates the result, then applies it as one settings update. Runtime
palette/key changes are session-only. Ches never writes user configuration or
persists preference overrides. A failed reload preserves active settings; a failed
startup uses defaults and reports the diagnostic. Buffers and unsaved edits survive.

Path: absolute nonempty `$XDG_CONFIG_HOME/ches/config.ml`, otherwise
`$HOME/.config/ches/config.ml`. Missing file means defaults. Existing
`snippets.json` remains independently loaded; no format migration in this phase.

```ocaml
open Ches_config

let () =
  Completion.set_enabled true;
  Completion.set_ghost_preview false;
  Completion.set_min_prefix_chars 1;
  Completion.set_prefer_local_snippets true;
  View.set_line_numbers false;
  Theme.set "vim-classic"
```

## Implementation boundary

1. `config/`: validated immutable Settings snapshot and standalone Stdlib-only
   `Ches_config` API source. A helper compiles the embedded API, user source and
   result writer using `ocamlc`, then runs the program outside the editor. No Dune,
   installed Ches `.cmi`, PPX, or editor dependencies are required for user configs.
   The API resets defaults in every fresh helper. Results use a versioned internal
   protocol; output/diagnostics and execution time are bounded, child processes
   are cleaned up, and no shell evaluates user paths. Config code is ordinary
   executable OCaml, not a sandbox. Failed compilation retains filename/line context.
2. `screen/`, `input/`, `palette/`, `completion/`: apply supported settings,
   configurable prefix/ranking, Reload configuration action and async generation
   request/result boundary. Validate themes before applying anything. Defaults
   are completion on, ghost off, prefix1, local snippets preferred, numbers off,
   theme vim-classic. Explicit CLI theme overrides config. Reload resets supported
   settings, dismisses transient completion safely, and preserves buffer contents.
3. `ui/`, `bin/`: load config before interactive startup; runtime reload uses the
   same helper asynchronously and latest-generation guards. Existing startup
   overrides/test assembly must stay intact; no config writes on toggle or exit.

## Validation and policies

Real compile/evaluate success and errors, missing file/compiler, invalid values,
timeouts, source filenames with spaces, bounded diagnostics/protocol errors;
screen reload/reset/failure atomicity and CLI precedence; real startup/runtime
wiring; full build and tests. Up to three agents, six jobs each, total cap20.
No staging/commits/pushes or modification of personal config files.

## Status

Implemented and validated. `Ches_config_runtime` exposes settings and loader APIs;
the embedded Stdlib API is compiled afresh on each explicit load using `ocamlc`
from PATH. No external Ches installation libraries are needed. There is no cache
yet. Private helper processes use a dedicated versioned result file, original
source line directives, bounded output/reads, compile/runtime deadlines, and
process-group cleanup. Technical details are in `config/README.md`.

Production startup awaits the result before mounting the terminal app. Explicit
CLI theme overrides survive reloads; `--list-themes` bypasses execution. Direct
test app assembly does not unexpectedly execute user configuration. Runtime loads
are asynchronous and latest-generation guarded. No toggle/exit writes settings.
Existing user snippets retain their separate JSON loading path.

Screen application validates everything before any mutation, rebuilds supported
preferences, and preserves buffers/unsaved text. Reload failures retain active
settings; startup failures apply defaults and report a diagnostic. Line numbers
apply to both presentation profiles. Completion threshold counts Unicode scalars,
and local snippet preference controls ranking rather than eligibility.

Review fixed bounded-error reporting for malformed numeric protocol values and
strict hex validation for theme payloads. Regression coverage also proves that
compile failures never execute user code, missing config does not need a compiler,
and child process groups are cleaned up after success as well as timeout.

Passed full `dune build -j6 @all` / `dune runtest -j6` and `git diff --check`, plus
real compiler, PTY CLI, configuration host, screen/palette, and completion tests.
No personal configuration files were created or changed. User-facing examples
and behavior are documented in `docs/configuration.md` and `docs/config.example.ml`.
