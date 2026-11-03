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
    ; snippets : Ches_completion.User_snippets.operation list
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
`"vim-classic"`, `[]`. Validation requires a positive minimum prefix and a theme that
is nonempty after trimming whitespace. The screen must check theme existence
before applying the snapshot. It validates every snippet operation against the
builtin catalog using `User_snippets.apply`. `Settings` also derives `sexp` and `equal`.

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
module Snippets : sig
  val add : id:string -> prefix:string -> ?scope:string list -> ?collection:string -> ?description:string -> string -> unit
  val disable : id:string -> unit
  val set_collection_enabled : collection:string -> bool -> unit
end
```

Snippet declarations are ordered: the last operation for an ID wins, including
overrides and disables of builtin IDs. Omitted or empty scope is global. Supported
scopes are `systemverilog`, `verilog`, `ocaml`, and `.filename-extension` values
without whitespace or slashes. Each fresh helper starts with no declarations.
Collection names consist of nonempty dot-separated ASCII alphanumeric, `_`, or
`-` segments. Membership is optional and independent of scope and origin. All
collections default to enabled; parent toggles match dotted descendants and the
last matching toggle wins. Toggles preserve definitions for later re-enabling;
individual disables remove definitions. Untagged declarations are unaffected by
collection toggles. An override uses its own membership, not the old declaration's.
The helper records strings; the host validates IDs, prefixes, descriptions,
scopes, and template syntax. An invalid operation (even one later overridden)
rejects the complete snapshot with its index and ID; callers retain prior settings.
Empty or whitespace-only IDs/prefixes are rejected. Text must be valid UTF-8 with
no NUL or CR; template bodies also obey `Snippet.parse` limits (65536 bytes).

Use OCaml quoted strings for multiline templates so template backslashes reach
the parser unchanged. If the body contains literal `|}`, use a named delimiter:

```ocaml
let () =
  Snippets.add ~id:"personal.example" ~prefix:"example"
    ~description:"Multiline choice and literal delimiter"
    {snippet|${1|first,second|}
literal |} and escaped dollar \$; $0|snippet};
  Snippets.disable ~id:"sv.aff"
```

The matching closing delimiter is `|snippet}`. In ordinary OCaml string literals,
backslashes must instead be escaped for OCaml as well as for snippet syntax.

Provider contract (`Ches_completion.User_snippets`):

```ocaml
type declaration =
  { id : string; prefix : string; scopes : string list
  ; collection : string option; description : string option; body : string }
[@@deriving sexp, equal]
type operation = Add of declaration | Disable of string
  | Set_collection_enabled of { collection : string; enabled : bool }
[@@deriving sexp, equal]
val apply : t -> operation list -> t Core.Or_error.t
```

`apply` preserves its immutable base, accepts at most 1000 ordered operations and
1 MiB of declaration strings, and validates every operation before returning a
catalog. Legacy `parse : string -> t Core.Or_error.t` remains available and still
rejects duplicate JSON user IDs. Apply OCaml operations to the chosen legacy/base
catalog to preserve legacy entries and give OCaml declarations precedence.

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
  rejected. The helper bounds its entire encoded result to 1 MiB before writing,
   and accepts at most **1000 snippet operations**. `CHES_SETTINGS_3` uses newline
  framing: magic; enabled; ghost; minimum prefix; prefer local; line numbers;
  hex theme; decimal operation count; then ordered operations. A `disable` tag
  is followed by hex ID. An `add` tag is followed by hex ID, hex prefix, decimal
   scope count, that many hex scopes, optional collection and description (each
   encoded as `none` or `some` followed by its hex value), and hex body. A
   `collection` operation tag is followed by hex collection name and enabled
   boolean. Version-2 decoding remains supported: adds have no collection field,
   and collection operations are unavailable. Every field ends in a newline; strings use lowercase
  hex, booleans are `true`/`false`, counts are canonical nonnegative decimals.
  The decoder rejects unsupported versions, malformed encodings/tags/counts,
  missing fields, and trailing data. Host validation is mandatory after decoding.
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

Validate an actual configuration through the same compiler, helper, decoder, and
host validators with:

```sh
dune exec -j 6 config/test/check_config.exe -- /absolute/path/to/config.ml
```

Success reports the operation count and exits zero; failures print diagnostics
and exit nonzero. As with `Loader.load`, a missing file means valid defaults.
