# Snippet config runtime

`Snippet_host` owns asynchronous loading for each `Editor_view` instance. After
ordinary state transitions, the frontend drains
`Ui_state.take_snippet_reload_requests` and schedules submission as an effect.
The host's reply pump injects a separate state-machine action, applying
`Ui_state.receive_snippets ~generation` and invalidating the frame cache.
Startup uses the screen's queued generation 1; **Reload snippets** follows the
same path. No filesystem work occurs in rendering or key transitions.

The path is `$XDG_CONFIG_HOME/ches/snippets.json` for a nonempty absolute XDG
value, otherwise `$HOME/.config/ches/snippets.json`. Missing HOME when needed is
an error. A missing file returns `User_snippets.builtins`; other read and parse
errors include the path. The runtime never creates files or directories.

Stat before opening rejects known special files; nonblocking open and descriptor
stat defend replacement with a FIFO. Reads consume at most 1 MiB plus one overflow
detection byte, and accept files exactly at the limit. Reading and pure parsing
both run on a worker thread. The descriptor is closed on every outcome.

There is one active load, one replaceable latest pending generation, and one
replaceable reply slot. Obsolete results are dropped by the host; screen also
rejects obsolete generations. Stop clears queued work and wakes the reply pump;
an already-running bounded read may finish in its thread but cannot publish or
launch another load. Exit/deactivation never wait on disk I/O.

`ui/picker_test/test_snippet_host.ml` covers paths, missing files, invalid JSON,
permissions, exact/overflow limits, FIFOs/directories, latest-only scheduling,
shutdown, and the actual Bonsai startup/palette effect path while editing.
