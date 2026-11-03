# OCaml configuration

[Documentation index](README.md) · [Editor reference](editor_reference.md)

Ches starts with built-in defaults and executes your OCaml configuration to change
them. Palette commands and keybindings subsequently change live session settings
only. Ches never rewrites your configuration or saves preference overrides.

## Location and first configuration

Create `~/.config/ches/config.ml`. If `XDG_CONFIG_HOME` is an absolute nonempty path,
use `$XDG_CONFIG_HOME/ches/config.ml` instead. Ches does not create the file for you.
An absent configuration uses the defaults and needs no compiler.

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
3. Validate all settings, including the theme.
4. Apply the complete result together.

Removing a setter restores that setting's default on reload. Successful reloads
discard temporary changes to supported settings while preserving buffers, unsaved
text, and unrelated layout preferences. Completion menus and theme previews are
dismissed when the new settings take effect. A missing file reloads defaults.

A compile, execution, or validation failure preserves the current settings and
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

User snippets remain in the independently loaded `snippets.json` collection for
now; this phase adds OCaml settings without migrating the snippet provider.
**Reload configuration** reloads `config.ml`; **Reload snippets** reloads that
collection. See [independent snippets](editor_reference.md#independent-and-user-defined-snippets)
for its existing format and scope rules.
