# Navigation preview integration contract

`Ches_navigation_preview_model.Model` is pure (Core, Ches_core, Ches_error).
`request = { generation; target }`, `snapshot = { request; state }`. The host
owns generation/stamp freshness and maps file failures to `Missing`/`Unreadable`.
`collect ~source ~target ~cancelled ~read` is synchronous worker work; read uses
the bytes/pos/len convention and returns zero at EOF. Exceptions propagate.
Cancellation returns `Cancelled`. `Disk { stamp }` is supplied by the host;
retained buffers use `of_buffer ~revision target buffer` and `Buffer { revision }`.

States: `Loading`, `Ready payload`, `Missing`, `Unreadable string`,
`Unsupported string`, `Limit string`, `Invalid_target string`, `Cancelled`.
Payload has `source`, zero-based `first_line`, `lines`, and `truncated`.
Each line has bounded valid UTF-8 `text`, half-open byte `highlights` (equal
endpoints mean a zero-width marker), and `truncated`. Selection, never the
declaration range, supplies highlights; CRLF terminators are excluded.

Limits: 8 MiB scanned/read, 4096 bytes/line, 64 KiB output, at most 32 lines;
window begins three lines before selection.start and ends twenty lines below.
Positions beyond scan/copy budgets produce explicit `Limit`, invalid coordinates
produce `Invalid_target`, invalid UTF-8/NUL produce `Unsupported`.

Picker API: `selected_identity : t -> int option` is the original input index.
`with_preview : t -> Model.state option -> t` attaches the current state.
UI integration clears it when the selected target snapshot changes; the picker
also clears on selection changes. Preview rendering never reads files or changes
focus. At least eight body rows are needed; smaller layouts retain the list.
Search ranking/counts and destination acceptance retain existing semantics.
