# Instance picker integration contract

`Instance_picker_tile.create ~module_name ~active instances` captures
`Language_query.instance` records (`hier_path : string`, `target : target option`).
`selected` returns the original record, including a missing target for top-level
instances. The host owns activation and navigation. Other entry points match the
destination picker (`query`, `fit`, `update`, `interpret`, `cursor`, `render`).

The list searches hierarchy paths, marks the current active path with `*`, and
keeps keyboard selection separate. Empty lists and empty search results render a
notice. Display clipping is Unicode-aware and bounds inspected bytes per row.

References use `Destination_picker_tile.create targets |> fun t ->
Destination_picker_tile.with_title t "Find references"`. Existing `create` callers
remain valid. The result title/footer include matching/total counts.

## Live protocol evidence

Early installed-server findings (2026-11-03): PATH is
`/home/wayne/slang-server/build/bin/slang-server`, version `0.3.1+a7a2d08`.
It advertises references, documentSymbol, getInstancesOfModule,
getActiveInstance, setActiveInstance, activateInstance and setBuildFile.
**Installed binary differs from cloned plugin:** plugin uses string
`interactionSource: "codeLensSelect"`; installed activateInstance rejects it with
`-32603: Failed to parse field 'interactionSource': rfl::Generic: Could not cast
the underlying value to an integer.` Source worker must account for this.

Opening a standalone `.sv` without selecting a build gives normal document
symbols/references and hover widths 8 and 32 together, but getInstancesOfModule
returns `[]`, getActiveInstance returns `null`, and setActiveInstance returns
`false`. A build-file probe is in progress to establish actual selection behavior.

Installed ocamllsp returns three standard Locations for `answer` (declaration
and two uses) with includeDeclaration=true, without a project build. Raw request /
response evidence: `/tmp/opencode/instances-references-evidence.json`; reusable
scratch probe: `/tmp/opencode/instances_references_probe.py`.

### Build-selected probe (complete)

Scratch `probe.sv` contained `leaf #(parameter W=8)` with `logic [W-1:0]
data`, and `top` instantiating `leaf #(.W(8)) narrow()` and
`leaf #(.W(32)) wide()`. Scratch `design.f` listed its absolute path.
Only advertised commands were sent via workspace/executeCommand.

* `slang.setBuildFile`, arguments `["/tmp/.../design.f"]`: result `null`;
  this enables hierarchy enumeration. The command may write workspace scratch
  settings; all files are under the temporary workspace, which is removed.
* `slang.getInstancesOfModule`, arguments `["leaf"]`: result
  `[{"instPath":"top.narrow","instLoc":{"uri":"file:///tmp/.../probe.sv",
  "range":{"start":{"line":5,"character":16},"end":{"line":5,"character":24}}}},
  {"instPath":"top.wide","instLoc":{"uri":"file:///tmp/.../probe.sv",
  "range":{"start":{"line":6,"character":17},"end":{"line":6,"character":23}}}}]`.
  These are `instPath`/`instLoc`, **not** `hierPath`/`location`.
* `slang.getActiveInstance`, arguments `["leaf"]`: same single object shape,
  initially `top.narrow`; `["nonexistent"]` returns `null`.
* `slang.getInstancesOfModule`, arguments `["top"]`: one object `instPath:"top"`
  with `instLoc` pointing to the module's full range `(4,0)..(7,9)`;
  **this binary does return a location for the top level**.
  `slang.getHierLocation` is **not advertised** (and was not sent); the
  advertised `slang.showHierLocation` is a client-navigation command. Use the
  returned `instLoc` for the editor's own validated destination flow.
* `slang.setActiveInstance`, arguments `["top.narrow"]` / `["top.wide"]`:
  `true`; subsequent getActiveInstance confirms each new path. Sends
  `workspace/codeLens/refresh` and `workspace/inlayHint/refresh` requests;
  no `slang/activeInstanceChanged` observed for this command.
* `slang.activateInstance`, arguments
  `[{"hierPath":"top.narrow","interactionSource":1}]` (also wide): `true`;
  getActiveInstance confirms switch. Emits
  `slang/activeInstanceChanged` with
  `{"hierPath":"top.narrow","interactionSource":"codeLensSelect"}` (string
  in notification despite integer required in request), plus refresh requests.
  No workspace/applyEdit or window/showDocument observed.
* **Hover width does not change after selection on this installed binary.**
  Before selection and after both successful set/activate commands, hovering
  `(1,17)` returns the same Markdown containing both `Type: logic[7:0]`,
  `Width: 8` and `Type: logic[31:0]`, `Width: 32`. This is runtime evidence,
  not an assumption that the newest cloned server code behaves identically.
* documentSymbol returns hierarchical DocumentSymbols for `leaf` (kind 2,
  range `(0,0)..(3,9)`) and `top` (kind 2, range `(4,0)..(7,9)`). Nested
  instantiation declarations also have kind 2/name `leaf`; do not select them
  as containing module definitions solely based on kind/name.
* Slang references at `data` return two Locations `(1,16)..(1,20)` and
  `(2,9)..(2,13)` with includeDeclaration=true.
* ocamllsp PATH `/home/wayne/.opam/5.2.0+ox/bin/ocamllsp` advertises references
  and returns three Locations for `let answer = 42` followed by
  `let result = answer + answer`: `(0,4)..(0,10)`, `(1,13)..(1,19)`,
  `(1,22)..(1,28)`. Shutdown/exit succeeded after omitting null params.

No source builds/downloads or personal configuration changes were used.

## Pure-view verification

`dune runtest -j6 --build-dir /tmp/opencode/ches-instance-picker-build screen/test`
passes in the development profile. New tests cover active versus selected marks,
original target identity, hierarchy filtering/empty results, scrolling, Unicode
query editing, tiny viewports, a million-byte combining-mark path with bounded
render allocation, and references headings/counts while preserving navigation.
Active-path comparisons and search ranking happen at creation/query updates;
rendering uses cached indices and clips bytes before building spans.
