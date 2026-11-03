# Navigation preview screen/host contract

The screen exposes these stable, non-draining operations (Model is
`Ches_navigation_preview_model.Model`):

```ocaml
val navigation_preview_request : t -> Model.request option
val navigation_preview_buffer : t -> Model.request -> Model.state option
val receive_navigation_preview : t -> Model.snapshot -> t
```

After each transition the host follows `navigation_preview_request`, cancelling
obsolete work and debouncing the newest request. After debounce it calls
`navigation_preview_buffer` against the **current installed UI state**. `Some`
is the bounded retained-buffer result (including dirty text); `None` permits the
host's bounded disk collector. Deliver `{ request; state }` through
`receive_navigation_preview`, then redraw/follow requests as for any transition.
The host must not activate/open a buffer to obtain this snapshot.

Requests use `{ generation : int; target }`. The getter is pure and stable;
selection, originating navigation lifetime and retained target lifetime/revision
changes replace the generation. Closing/empty/invalidated pickers expose `None`.
Replies must match the exact current request, selected destination and origin;
buffer replies must additionally match the current retained document/revision.
Thus A→B→A cannot reuse the first A's reply.

Rendering and selection do not read file contents. Destination acceptance uses
bounded file metadata (device/inode/size/mtime/ctime), captured at results arrival
and checked at disk-preview delivery and acceptance, instead of whole-file digests.
The disk-delivery check is metadata only, via `Ches_app.Navigation_file_stamp`;
the payload's serialized observation must also match the stamp captured at results
arrival, so a window collected from another version cannot install merely because
the original path has since been restored. Stamps follow symlinks to regular files
and reject special files without opening them.
selection, rendering, and the request getter perform no filesystem access.
Metadata detects normal
replacement/edits but has a race window and cannot semantically verify that server
coordinates still identify the originally intended symbol.
