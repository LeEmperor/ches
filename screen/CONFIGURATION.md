# Configuration UI boundary

`Ui_state.create` queues no configuration load. The frontend preloads a complete
`Ches_config_runtime.Settings.t`, creates its initial state with existing assembly
options, then calls `apply_configuration ?theme_override state settings`. On startup
failure it applies `Settings.default` and reports the diagnostic with `with_notice`.
An explicitly supplied `create ~theme` is retained as an override; the optional
`apply_configuration ~theme_override` also records an override for future reloads.

`apply_configuration` validates the complete snapshot and resolves its theme before
changing any state, even when a CLI override is present. Failure returns `Error`
without dismissing completion or changing buffers/preferences. Success replaces all
supported settings, dismisses completion and theme preview, and preserves text and
unrelated layout preferences. Numbers map to Absolute/Off in both presentation profiles.

Palette `configuration.reload` / `Reload_configuration` only queues a generation.
Drain `take_config_reload_requests`, run the helper outside screen, and deliver
`receive_configuration ~generation result`. Only the newest pending generation can
apply or report feedback; duplicate/stale results are ignored. Each helper result
must be a fresh defaults-based snapshot, so removed settings and session toggles
reset on successful reload. Failed reloads preserve active settings. Screen performs
no configuration/source/file IO and never persists session preferences.
