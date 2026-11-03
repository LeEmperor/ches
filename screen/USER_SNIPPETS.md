# User snippet runtime boundary

The UI worker drains `Ui_state.take_snippet_reload_requests : t -> t * int list`
and returns each asynchronous load with
`Ui_state.receive_snippets : t -> generation:int -> (Ches_completion.User_snippets.t, string) Result.t -> t`.
Creation queues generation 1 and immediately uses `User_snippets.builtins`.
`Reload_snippets` (palette title **Reload snippets**, ID `snippets.reload`)
increments the generation and queues a new request. Drain is destructive; each
generation is delivered once. Only the latest requested generation is accepted;
older successes and failures are ignored. Reload dismisses the completion menu
and cancels its token, preventing late source results from restoring old menus.
Success replaces the catalog and posts a notification; failure posts an error
notification and preserves the last good catalog. Screen transitions perform no I/O.

The UI worker owns disk reads, bounds and parsing. Follow
`docs/plans/user_snippets.md`: use absolute nonempty `$XDG_CONFIG_HOME` plus
`ches/snippets.json`, otherwise `$HOME/.config/ches/snippets.json`. Missing files
return `Ok User_snippets.builtins`; do not create directories or files. Parse
version 1 configuration with `User_snippets.parse` and convert errors to strings
for this boundary. Run reads asynchronously, then feed the returned state through
the ordinary UI update/render loop.
