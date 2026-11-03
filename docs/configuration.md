# OCaml configuration

[Documentation index](README.md) · [Editor reference](editor_reference.md)

Ches starts with built-in defaults and executes your OCaml configuration to change
them. Palette commands and keybindings subsequently change live session settings
only. Ches never rewrites your configuration or saves preference overrides.

## Location and first configuration

Create `~/.config/ches/config.ml`. If `XDG_CONFIG_HOME` is an absolute nonempty path,
use `$XDG_CONFIG_HOME/ches/config.ml` instead. Ches does not create the file for you.
An absent configuration uses the defaults and needs no compiler.

From the command palette (`Space c c`), choose **Open configuration** to open this
exact path in Ches. Existing unsaved config buffers are reused. If the file does
not exist, it opens as an unsaved buffer; the command does not create files or
directories or execute configuration. Save normally, then use **Reload
configuration** to apply it. If the parent directory is absent, create it before
saving.

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

This example specifies the current defaults. Change or omit whichever lines you
like. An editable copy is available as [config.example.ml](config.example.ml).

The file is real executable OCaml: you can use local functions, conditionals, and
the standard library. For example:

```ocaml
open Ches_config

let () =
  View.set_line_numbers true;
  match Sys.getenv_opt "CHES_GHOST" with
  | Some "1" -> Completion.set_ghost_preview true
  | _ -> ()
```

## Supported settings

| Setter | Default | Meaning |
| --- | --- | --- |
| `Completion.set_enabled` | `true` | Automatically request suggestions while typing |
| `Completion.set_ghost_preview` | `false` | Preview a simple selected completion suffix |
| `Completion.set_min_prefix_chars` | `1` | Positive number of identifier characters needed for automatic completion |
| `Completion.set_prefer_local_snippets` | `true` | Rank local snippet candidates ahead of LSP candidates |
| `View.set_line_numbers` | `false` | Show absolute line numbers; applies across presentation profiles |
| `Theme.set` | `"vim-classic"` | Select a built-in theme by ID |

Manual Ctrl-n and punctuation triggers bypass the minimum-prefix setting. Turning
off local-snippet preference changes ranking, not availability. Prefix scanning
remains bounded at 4096 bytes, so very large thresholds can suppress automatic
identifier suggestions. Use `ches --list-themes` to find theme IDs; this command
does not execute configuration. An explicit `--theme NAME` takes precedence over
configuration at startup and on reload.

These setters are the initial supported API. Other editor options retain their
existing CLI/keybinding behavior; arbitrary editor commands and external OCaml
packages are not exposed through this configuration API.

## Session changes and reload

After startup, toggling line numbers, completion, ghost text, or the theme affects
only the running session. To make a setting permanent, edit `config.ml`.

Select **Reload configuration** in the command palette (`Space c c`) to:

1. Construct fresh supported defaults.
2. Compile and execute your current configuration.
3. Validate all settings, including the theme and snippet declarations.
4. Apply settings and the snippet catalog together.

Removing a setter restores that setting's default on reload. Successful reloads
discard temporary changes to supported settings while preserving buffers, unsaved
text, and unrelated layout preferences. Completion menus and theme previews are
dismissed when the new settings take effect. A missing file reloads defaults.

A compile, execution, or validation failure preserves the current settings/catalog and
reports the error. At startup, failure uses defaults and reports the diagnostic
after opening the editor. Compiler errors reference the original filename and line.

## Execution requirements

`ocamlc` must be on `PATH` when `config.ml` exists. Ches embeds the small
Stdlib-only `Ches_config` API and compiles it with your file into a temporary helper.
No installed Ches development libraries, Dune invocation, or PPX dependencies are
needed. Every startup and explicit reload compiles afresh; there is no compiled
configuration cache yet.

Startup waits for configuration before mounting the interactive UI. Reloading is
asynchronous; editing continues, and obsolete results cannot overwrite a newer
reload. Compilation has a ten-second deadline and execution a two-second deadline.
Config source and result sizes are bounded at 1 MiB. Helpers and temporary files
are cleaned up after success or failure.

The helper runs in a private temporary working directory, so use absolute paths
for any files your configuration reads. It executes ordinary OCaml code, rather
than a sandboxed expression language. Ches itself does not write your config file.

## Snippets

Define templates in `config.ml` with `Snippets.add`:

```ocaml
let () =
  Snippets.add
    ~id:"personal.module"
    ~prefix:"mymod"
    ~scope:[ "systemverilog" ]
    ~description:"Module named after this file"
    {snippet|module ${1:${TM_FILENAME_BASE:untitled}} (
    $0
);
endmodule|snippet}
```

The filename supplies the first field's default, which stays selected and editable
after acceptance. Linked `$1` occurrences would mirror edits to it. The same body
syntax supports ordinary defaults and choices. Use **named quoted strings** such
as `{snippet|...|snippet}` when a body contains choices: the choice ending `|}`
would prematurely close an unnamed `{|...|}` string. Named strings also let you
include quotes and backslashes without OCaml escaping.

API:

```ocaml
Snippets.add ~id ~prefix ?scope ?collection ?description body
Snippets.disable ~id
Snippets.set_collection_enabled ~collection enabled
```

- `id` is a stable identity; matching IDs override earlier declarations or starters.
- `prefix` is the case-sensitive completion trigger. `description` is optional.
- Omitted or empty `scope` is global. Recognized scopes are `"systemverilog"`,
  `"verilog"`, `"ocaml"`, or extensions such as `".py"`.
- `collection` optionally groups templates independently of file scope. All
  collections default to enabled; untagged templates remain enabled. Use
  `Snippets.set_collection_enabled ~collection:"hardcaml" false` to hide a
  collection and its dotted descendants. The last matching toggle wins.
- Collection toggles preserve definitions for re-enabling; `disable ~id` removes
  an individual definition. Overrides use their own metadata and do not inherit
  the old collection. See [collections and bundled templates](snippets.md) for
  examples, naming rules, dependencies, and available triggers.
- Declarations execute in order: the last operation for an ID wins. For example,
  `Snippets.disable ~id:"sv.aff"` removes the bundled clocked-block template.
- Every declaration is validated, including ones replaced later. Errors identify
  the offending ID and reject the entire settings/catalog update.
- A fresh evaluation begins with no OCaml snippet operations. Removing a declaration
  restores the underlying template on the next successful reload.

See [snippets.example.ml](snippets.example.ml) for copyable templates and
[snippet controls](editor_reference.md#snippet-placeholders) for supported syntax.

To discover templates without remembering prefixes, choose **Insert snippet**
from the palette in a file's Normal mode. Search by prefix, description, ID, or collection;
the preview identifies the effective declaration's origin (bundled, legacy JSON,
or OCaml), scope, collection, and raw body when space permits. Enter inserts the selected
template at the cursor and activates its fields. Escape cancels without editing.

### Legacy JSON compatibility

An existing `snippets.json` remains supported. Effective order is **bundled
starters → legacy JSON → OCaml declarations**. Delayed JSON loads and **Reload
snippets** reapply the current OCaml layer, so they cannot overwrite your OCaml
definitions. **Reload configuration** applies settings and OCaml snippets together;
**Reload snippets** reloads only the legacy JSON base.

When migrating, transfer your definitions into `config.ml`, validate/reload it,
and move the JSON file to an inactive backup name. On restart, absent JSON means
the base contains bundled starters only. This is a manual migration; the editor
does not rewrite either file. The legacy format is documented in the
[editor reference](editor_reference.md#legacy-json-snippet-collection).
