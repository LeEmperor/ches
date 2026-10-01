# Ches Editor Prototype Brief

## Goal

Build a small but architecturally clean prototype of a custom programmer's editor written in **OCaml / OxCaml**.

The intent is **not** to recreate Neovim, Emacs, or VS Code in the first pass. The initial goal is a fast, modal, keyboard-driven editor with a clean core that can later grow into a more capable IDE-like environment.

The user comes primarily from:

- Neovim
- Doom Emacs
- OCaml / Jane Street tooling
- systems / RTL / low-latency engineering

The prototype should therefore emphasize:

- low latency
- modal editing
- composable commands
- testable editor state
- clean separation between core editor logic and UI
- OCaml-native architecture
- future extensibility without designing a plugin ecosystem yet

---

# High-Level Philosophy

Treat the editor as several independent systems:

1. **Text engine**
   - buffers
   - cursor positions
   - insert/delete
   - selections
   - undo/redo

2. **Command/input engine**
   - Vim-like modes
   - motions
   - operators
   - keymaps

3. **UI/rendering**
   - terminal first
   - GUI potentially later

4. **Language tooling**
   - syntax highlighting
   - LSP
   - diagnostics
   - completion

5. **Workspace layer**
   - files
   - buffers
   - splits
   - project search
   - fuzzy file opening

6. **Extensibility/configuration**
   - defer plugin-system design
   - keep internals modular enough to expose later

The first prototype only needs a subset of these.

---

# Recommended Architecture

The editor core should be completely independent of Bonsai, terminals, GUI code, or rendering.

Conceptually:

```text
input
  |
  v
+----------------------+
|      ches_core        |
|----------------------|
| Buffer               |
| Cursor               |
| Selection            |
| Motion               |
| Operator             |
| Command              |
| Undo                 |
| Editor_state         |
+----------+-----------+
           |
           v
+----------------------+
|      ches_ui          |
|----------------------|
| Bonsai               |
| Bonsai_term          |
+----------+-----------+
           |
           v
        terminal
```

The core should be testable with no UI:

```ocaml
let state = Editor.empty in
let state = Editor.dispatch state (Insert "hello") in
let state = Editor.dispatch state (Move Left) in
let state = Editor.dispatch state (Operate (Delete, Word_forward)) in
...
```

---

# TUI Choice

## Recommended: Bonsai + Bonsai_term

Use **Bonsai_term** for the prototype UI.

Why:

- naturally fits reactive editor state
- incremental computation model
- composable UI components
- aligns well with Jane Street / OCaml ecosystem
- good support for expect-test-style UI testing
- future Bonsai-based frontends may be possible without rewriting the editor core

The editor should still avoid deeply coupling the text engine to Bonsai.

Good boundary:

```text
ches_core
  -> immutable / persistent logical editor state
  -> Bonsai UI derives visible state
  -> Bonsai_term renders it
```

Avoid putting the fundamental rope/buffer implementation directly into `Bonsai.state` everywhere.

## Alternative: Notty + Nottui

Notty/Nottui is also reasonable and likely simpler for a tiny TUI.

Use it instead only if the priority becomes:

- minimal conceptual overhead
- direct terminal control
- fastest path to "text appears on screen"

For this project, however, Bonsai_term is preferred because the goal is likely to grow past a tiny demo.

---

# Rendering Guidance

For the concrete MVP0 visual direction and layout contracts, see
[`rendering_design.md`](rendering_design.md) and phase 6 of
[`mvp0_plan.md`](mvp0_plan.md). These add a richly colored, finely framed document
view, responsive centered placement, adjustable width/horizontal offset, and
Normal-mode layout controls. Placement preferences belong to the UI and do not
change the buffer representation or editor semantics. Future supporting tiles
are described separately from the MVP0 scope in that companion document.

Do **not** model every character cell as an independent Bonsai component.

Prefer coarse-grained rendering:

```text
Buffer_view.component
    |
    v
calculate visible lines
    |
    v
render rectangular viewport
```

The UI should care primarily about:

- currently visible lines
- cursor position
- mode
- status line
- optionally a small file/buffer list

Treat the editor as a latency pipeline:

```text
keypress
  -> decode key
  -> resolve command
  -> update editor state
  -> determine visible changes
  -> render viewport
  -> terminal output
```

The important performance characteristic is interactive latency, especially keystroke-to-frame latency.

---

# Text Storage

Do not use a plain string as the long-term editing structure.

Potential choices:

- gap buffer
- rope
- piece table
- piece tree

For an OCaml implementation, a **rope** or **piece table** is especially attractive.

## Preferred direction

Start with one of:

### Option A: Rope

Advantages:

- natural fit for persistent / immutable OCaml data structures
- efficient insert/delete
- cheap structural sharing
- good for large files
- potentially elegant undo snapshots

### Option B: Piece Table

Advantages:

- original file buffer remains unchanged
- edits append into a secondary buffer
- document is represented by references into original/add buffers
- undo/redo maps naturally onto edit history

For the very first demo, a simpler representation may be acceptable if the abstraction boundary is designed so the storage engine can later be replaced.

Example abstraction:

```ocaml
module type BUFFER = sig
  type t

  val of_string : string -> t
  val to_string : t -> string

  val insert :
    t ->
    position:int ->
    string ->
    t

  val delete :
    t ->
    position:int ->
    length:int ->
    t
end
```

---

# Editing Model

Favor typed editor commands.

Example:

```ocaml
type mode =
  | Normal
  | Insert

type motion =
  | Left
  | Right
  | Up
  | Down
  | Word_forward
  | Word_backward
  | Line_start
  | Line_end

type operator =
  | Delete
  | Change
  | Yank

type command =
  | Move of motion
  | Operate of operator * motion
  | Insert_text of string
  | Enter_insert_mode
  | Enter_normal_mode
  | Undo
  | Redo
  | Save
  | Quit
```

Then keyboard handling is a separate mapping layer:

```text
keypress
   |
   v
keymap
   |
   v
Command.t
   |
   v
Editor.dispatch
```

This separation is important.

It makes it possible later to drive the editor through:

- keyboard bindings
- macros
- scripts
- tests
- RPC
- AI agents
- future plugins

without duplicating editor logic.

---

# Modal Editing

The first prototype should imitate only a small useful subset of Vim.

Recommended initial modes:

- Normal
- Insert

Recommended first motions:

- `h`
- `j`
- `k`
- `l`
- `w`
- `b`
- `0`
- `$`

Recommended first actions:

- `i`
- `a`
- `x`
- `dd`
- `dw`
- `u`
- redo
- save
- quit

Do not try to implement full Vim semantics immediately.

---

# Undo / Redo

Undo is one of the first editor features that becomes subtle.

For the prototype:

- represent edits as transactions
- group contiguous typing in insert mode into a single undo unit if convenient
- make undo/redo operate at command/edit-transaction granularity

Potential structure:

```ocaml
type edit =
  | Insert of
      { position : int
      ; text : string
      }
  | Delete of
      { position : int
      ; text : string
      }

type transaction = edit list
```

A persistent buffer model may later allow undo to reference prior buffer states directly.

---

# Suggested Project Layout

```text
ches/
├── dune-project
├── bin/
│   └── ches.ml
│
├── core/
│   ├── buffer.ml
│   ├── cursor.ml
│   ├── selection.ml
│   ├── motion.ml
│   ├── operator.ml
│   ├── command.ml
│   ├── transaction.ml
│   ├── undo.ml
│   ├── editor_state.ml
│   └── editor.ml
│
├── ui/
│   ├── app.ml
│   ├── buffer_view.ml
│   ├── status_bar.ml
│   ├── keymap.ml
│   └── terminal.ml
│
└── test/
    ├── buffer_tests.ml
    ├── command_tests.ml
    ├── editor_tests.ml
    └── ui_expect_tests.ml
```

Potential later expansion:

```text
language/
  lsp.ml
  diagnostics.ml
  completion.ml
  highlighting.ml

workspace/
  project.ml
  file_picker.ml
  buffers.ml
  splits.ml
```

---

# MVP: Basic Demo

The first demo should be intentionally small.

## Required

- launch from terminal:
  ```bash
  ches some_file.ml
  ```

- load a text file

- render the file inside a terminal UI

- show a cursor

- support terminal resize

- Normal mode

- Insert mode

- basic movement:
  - `h`
  - `j`
  - `k`
  - `l`

- insert characters

- backspace/delete

- save file

- quit

- status line showing:
  - mode
  - filename
  - line
  - column

- core logic separated from Bonsai_term

## Strongly Recommended

- `w` / `b`
- `0` / `$`
- undo
- redo
- simple search
- viewport scrolling
- basic syntax coloring if trivial

## Explicitly Out of Scope for V0

Do **not** spend time on:

- plugin system
- embedded terminal emulator
- Git UI
- debugger
- AI integration
- multiple cursors
- remote SSH
- browser support
- GUI frontend
- full Vim compatibility
- LSP
- Tree-sitter
- project indexing
- fuzzy finder
- file tree
- collaborative editing

Those are later milestones.

---

# Suggested Demo UI

Something as small as:

```text
+--------------------------------------------------+
| let foo x = x + 1                               |
|                                                  |
| let bar = foo 41                                |
|                                                  |
|                                                  |
|                                                  |
|                                                  |
+--------------------------------------------------+
| NORMAL   demo.ml                     Ln 2 Col 1  |
+--------------------------------------------------+
```

Insert mode:

```text
| INSERT   demo.ml                     Ln 2 Col 8  |
```

No sidebar is needed initially.

---

# Bonsai Usage Guidance

Use Bonsai for:

- UI composition
- UI-local state
- event routing
- rendering
- focus
- terminal resize handling
- asynchronous effects later

Do not use Bonsai as the implementation of:

- text-buffer algorithms
- cursor semantics
- motion semantics
- edit transactions
- undo semantics

Those belong in `ches_core`.

Potential UI structure:

```text
Editor.component
|
+-- Buffer_view.component
|
+-- Status_bar.component
|
+-- optional Completion_popup.component
```

For the first demo, only `Buffer_view` and `Status_bar` are necessary.

---

# Testing Strategy

Use normal unit tests for core behavior.

Example:

```ocaml
let%expect_test "insert text" =
  let state =
    Editor.empty
    |> Editor.dispatch Enter_insert_mode
    |> Editor.dispatch (Insert_text "abc")
  in
  print_s [%sexp (state : Editor_state.t)];
  ...
```

Test motions independently.

Examples:

```text
start at column 5
Move Left
expect column 4
```

Test delete semantics independently.

Bonsai_term rendering should ideally use expect/snapshot tests.

Example conceptual test:

```ocaml
let%expect_test "empty editor" =
  ...
```

and expect a stable terminal rendering.

This is especially valuable because UI regressions can be reviewed as textual diffs.

---

# Performance Direction

The editor should eventually be optimized around interactive latency rather than synthetic throughput.

Useful metrics:

- startup latency
- keypress-to-render latency
- file-open latency
- insert/delete complexity
- search throughput
- memory usage
- large-file responsiveness
- LSP isolation
- syntax-highlighting latency

Long-term aspirational targets might look like:

```text
warm startup:           < 10 ms
normal keypress path:   < 2 ms typical
10 MB file open:        effectively immediate
large-file editing:     should not require copying entire buffer
LSP:                    never block editor input
syntax parsing:         incremental / asynchronous
```

Do not prematurely optimize V0.

First preserve the architecture required to optimize later.

---

# Future Language Tooling

After the editor core is solid:

## LSP

Implement an LSP client rather than implementing language semantics directly.

Potential servers:

- `ocamllsp`
- `clangd`
- `rust-analyzer`
- etc.

Potential features:

- diagnostics
- hover
- go-to-definition
- completion
- references
- formatting
- document symbols

LSP must be asynchronous and must never block editing.

Version documents so stale LSP responses can be rejected.

---

# Future Syntax Highlighting

Prefer incremental parsing rather than custom language parsers.

Tree-sitter is a likely future choice.

Conceptually:

```text
buffer edit
   |
   +------> incremental parser
   |             |
   |             v
   |         syntax tree
   |             |
   v             v
viewport ----> highlighting
```

For V0, syntax highlighting can be omitted entirely.

---

# Future GUI

Bonsai creates an interesting path toward multiple frontends.

Potential architecture:

```text
                 ches_core
                    |
             shared editor model
                    |
               ches_bonsai
                /     \
               /       \
      Bonsai_term    Bonsai_web
           |             |
        terminal       browser
```

The exact GUI technology can be decided later.

Do not build the core around terminal assumptions.

---

# Extensibility Philosophy

Do not design a plugin ecosystem in V0.

Instead, keep APIs modular enough that a future extension layer could expose things like:

```ocaml
register_command
register_keymap
register_language
register_panel
register_hook
```

The editor is already written in OCaml, so initial configuration may simply be compiled OCaml configuration rather than inventing a scripting language.

Avoid turning the project into "Emacs implemented from scratch."

---

# Important Engineering Invariants

The implementation should make these concepts explicit:

## Buffer Version

Every edit increments a buffer version.

Useful later for:

- LSP
- syntax parsing
- async search
- background tasks

Never apply asynchronous results blindly to a newer document.

## Cursor Validity

After every edit:

```text
0 <= cursor <= buffer_length
```

For line/column movement, define behavior clearly around:

- empty lines
- end-of-line
- final newline
- file boundaries

## Command Purity

Prefer:

```ocaml
Editor.dispatch :
  Editor_state.t ->
  Command.t ->
  Editor_state.t
```

for core synchronous behavior.

I/O such as saving should be represented explicitly as effects/actions where practical.

## UI Independence

`ches_core` should compile and test without Bonsai_term.

---

# OxCaml Direction

OxCaml is an interesting long-term fit, but V0 should prioritize correctness and architecture.

Potential future optimization areas:

- reduced allocation in rendering paths
- carefully mutable scratch buffers
- ownership/locality-aware hot paths
- efficient persistent editor state
- project indexing
- parsing
- async language tooling

A useful mental split:

```text
mostly functional control plane
+
carefully mutable performance-sensitive data plane
```

For example:

```text
Editor state / commands
        |
        v
persistent logical buffer
        |
        v
mutable rendering scratch buffers
parser caches
terminal output buffers
```

---

# Agent Implementation Request

Build a minimal working prototype called **Ches**.

Prioritize correctness and clean architecture over feature count.

The first milestone should:

1. open a file
2. render it with Bonsai_term
3. move a cursor with `h/j/k/l`
4. enter Insert mode with `i`
5. type text
6. leave Insert mode with Escape
7. save
8. quit
9. show mode/file/line/column in a status bar
10. keep all editor semantics in a UI-independent `ches_core`

Do not implement LSP, Tree-sitter, plugins, multiple panes, Git, or an embedded terminal yet.

Use expect tests where practical.

Keep the architecture replaceable enough that the initial text storage can later become a rope or piece table.

The output should be a compilable Dune project with a README explaining:

- how to build
- how to run
- implemented keybindings
- current architecture
- known limitations
- next recommended milestones
