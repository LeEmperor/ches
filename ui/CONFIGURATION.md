# Configuration runtime integration

`Editor_view.run` awaits `Configuration_host.startup` before creating the terminal
runtime or mounting Bonsai_term. It passes the complete loader result to `app`.
The initial screen applies the snapshot using `Ui_state.apply_configuration`;
load or validation failure applies `Settings.default` and posts a configuration
notification containing the diagnostic. Existing controller and assembly options
are retained. An explicit `theme` is passed as `theme_override` and retained by
screen across reloads. The CLI parses `--theme` as an option, so omission does not
override the configuration. `--list-themes` returns before `run` and never loads it.

Direct `Editor_view.app` assembly does not execute startup configuration. Tests can
inject `startup_configuration` (including an error) and a `Configuration_host`
whose `load` function is local to that instance. `run` accepts the same overrides;
without a preloaded result it awaits that host's loader.

After a full transition, the frontend drains `take_config_reload_requests` and
schedules host submission as an effect. A separate lifecycle pump delivers replies
as configuration actions, invalidates the frame cache, and calls
`receive_configuration ~generation` on the current model. Neither keys nor frames
perform configuration I/O. The host runs one load and retains only the latest
pending generation and latest reply. Host and screen both reject obsolete results.

Exit/deactivation stops the host, clears pending work and wakes its reader. An
already active loader is allowed to finish its bounded work and child cleanup;
its result is ignored and it cannot launch pending work. Production awaits
`Configuration_host.shutdown` after restoring the terminal and at process shutdown,
so the scheduler stays alive for bounded child cleanup. The loader owns compiler
and evaluator processes, limits and temporary-file cleanup. Runtime preferences
and exit never write configuration. Snippet loading remains independent.

`ui/picker_test/test_configuration_host.ml` exercises the real compiler-backed
startup snapshot, injected scheduling, reload effects during edits, error handling,
theme override, stop behavior and unchanged configuration source.
