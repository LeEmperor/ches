# Executable configuration runtime

Editor library: `Ches_config_runtime` (`core`/`async` internally). Public entry points:

```ocaml
module Settings : sig
  type t =
    { completion_enabled : bool
    ; completion_ghost_preview : bool
    ; completion_min_prefix_chars : int
    ; completion_prefer_local_snippets : bool
    ; line_numbers : bool
    ; theme : string
    }
  val default : t
  val validate : t -> t Core.Or_error.t
end

module Loader : sig
  val config_path : getenv:(string -> string option) -> string option
  val load : ?path:string -> unit -> (Settings.t, string) Result.t Async.Deferred.t
end
```

Defaults, in record-field order: `true`, `false`, `1`, `true`, `false`,
`"vim-classic"`. Validation requires a positive minimum prefix and a theme that
is nonempty after trimming whitespace. The screen must check theme existence
before applying the snapshot. `Settings` also derives `sexp` and `equal`.

## User API

The following is ordinary, executable OCaml using only Stdlib:

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

Exact supported signatures:

```ocaml
module Completion : sig
  val set_enabled : bool -> unit
  val set_ghost_preview : bool -> unit
  val set_min_prefix_chars : int -> unit
  val set_prefer_local_snippets : bool -> unit
end
module View : sig val set_line_numbers : bool -> unit end
module Theme : sig val set : string -> unit end
```

Invalid prefix/theme setters raise `Invalid_argument`. Snapshots are validated
again by the host. Other definitions in the embedded source are implementation
details, not supported user API.

## Loading and limits

- Resolve a nonempty absolute `$XDG_CONFIG_HOME/ches/config.ml`; otherwise use
  `$HOME/.config/ches/config.ml`. With no usable location or a missing file,
  return defaults. Other read, compile, execution, protocol, and validation errors
  return a diagnostic string. Explicit `~path` bypasses environment resolution.
- Every explicit load compiles afresh: there is **no cache**. The Dune-generated
  `Api_source` embeds the exact `ches_config.ml` source, then the loader writes
  that source, the user source, and a result writer into a private `0700` temp
  directory. `ocamlc` is resolved from `PATH`. No installed Ches `.cmi`, Dune,
  editor dependency, or PPX is needed to execute a user's configuration.
- Compiler diagnostics use an OCaml line directive for the original filename
  and line numbers. Argument vectors are passed directly, without a shell.
- Source and result reads are each capped at **1 MiB**; nonregular files are
  rejected. The helper bounds its own result to 1 MiB (theme payload at most
  **524,224 bytes**, encoded as hex). The `CHES_SETTINGS_1` protocol has six fields
  and strict framing. Host validation is mandatory after decoding.
- Stdout and stderr are drained independently, retaining at most **1 MiB each**.
  User printing cannot contaminate the dedicated `settings.result` file.
- Compilation deadline: **10 seconds**. Execution deadline: **2 seconds**.
  Each subprocess has a new process group; completion, failure, and timeout kill
  remaining group members and reap the direct child. After parent exit, pipe
  draining gets at most **100 ms** before readers are closed. Descendants that
  deliberately detach from the process group can escape this cleanup.
- Temporary files are removed on success and failure. The loader never writes
  the user's config. Working directory during execution is the private temp
  directory; relative user file access resolves there.
- This is executable user code, **not a sandbox**: filesystem access, process
  creation, memory use, and writes made by user code are not resource-limited.

`Loader.For_testing.load` additionally accepts local `getenv`, `compiler`,
`compile_timeout` (seconds), and `runtime_timeout` (seconds) overrides. Tests use
these to simulate absent compilers and deadlines without global environment
changes. Run `dune runtest config/test -j 6`.
