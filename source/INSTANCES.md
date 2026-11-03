# Instance and references transport contract

The shared API is `error/language_query.mli`. Requests retain the existing token,
cursor and kind shape. New kinds are `References`, `Instances`,
`Activate_instance { module_name; hier_path }`, and `Instantiation`.
Named payload types are `instance`, `instance_list`, and `instance_activated`;
results are `Instance_list`, `Instance_activated`, or the existing `Locations` /
`Failed`. Instance lists carry the exact negotiated `encoding` for `module_range`;
targets carry their own encoding. Convert with `Language_query.offset` only in
that encoding. Activation carries no coordinates: its origin retains the already
converted module range, so the activation payload needs no encoding field.

`Instance_context_changed { source; revision; module_name; hier_path }` is a
**connection-wide** event, deliberately not wrapped in document `Owned` routing.
The workspace rewrites `source` to the stable pool source ID, as for query replies.
`revision` increases within a session; lifecycle/restart clears known context.
Optional names describe confirmed context only (unknown notifications/refreshes
can carry neither). Consumers invalidate pending context-sensitive UI for every
document served by that source, including when the mutation's originating query
is no longer current. This event is not a navigation request.

Activation accepts only choices returned for the same document token generation,
text revision and server context. A fresh discovery is needed after context change.
Sending a mutation emits unknown-context invalidation immediately; confirmed success
emits its module/path. Failures never publish a speculative selected instance.
Mutation acknowledgement observers survive query cancellation and the ten-second
UI deadline, retaining a slot in the bounded pending-request budget until response
or session end. This preserves invalidation even for a late, stale acknowledgement.
References always use standard `textDocument/references`, include declarations,
and never fall back to declaration/definition. Instances use advertised commands,
server document symbols and filesystem paths; no source-text module parsing.

## Checked Slang compatibility

Inspected `/home/wayne/devel/slang-server` and `/home/wayne/devel/slang-server.nvim`:

- `slang.getModulesInFile` takes `[filesystemPath]`, not a URI.
- `slang.getInstancesOfModule` and `slang.getActiveInstance` take `[moduleName]`.
- Qualified instances contain `instPath` and deprecated `instLoc` (an LSP Location).
  Usable locations become safe direct targets. Missing/invalid locations remain
  absent; instantiation reports a top-level/no-location notice.
- Prefer advertised `slang.setActiveInstance` with `[hierPath]`. The alternative
  `slang.activateInstance` takes `[{hierPath, interactionSource:1}]`
  (`codeLensSelect`). The installed binary requires an integer in requests,
  despite string-valued notifications and the cloned plugin's string requests.
  Neither call requests focus or navigation.
- The clone registers `slang.showHierLocation`, which has client showDocument
  side effects, but no direct `getHierLocation` command. Ches does not invoke it.
- Module/Interface document symbols must enclose the cursor and belong to the
  current document. If available, the filesystem-path module index filters names;
  otherwise only those server-provided symbol identities are used. Nested variable
  symbols, included-file locations and another module in the file cannot supply
  a guessed identity.
- `slang/activeInstanceChanged` invalidates the entire connection. Standard
  inlay-hint, code-lens, semantic-token and diagnostic refresh requests also
  invalidate context and receive successful null acknowledgements.

Every pipeline flushes didChange before capturing its snapshot. One query per
document, a 32-slot connection budget and a shared ten-second chain deadline apply.
Restart creates a new session with empty command inventory, choices and context;
consumers clear their visible context on lifecycle/inventory changes.

## Installed hover response semantics

The live evidence in `screen/INSTANCE_PICKER.md` and
`/tmp/opencode/instances-references-evidence.json` is for Slang
`0.3.1+a7a2d08`. After successful selection and a separate getActiveInstance
confirmation, fresh hover responses themselves still contain both width-8 and
width-32 renderings. This is installed-server response behavior, not Ches
combining cached contexts or omitting an instance argument: standard
textDocument/hover takes only the document and position, and the selected instance
is server-side state. Ches preserves each returned Markdown value verbatim.

The inspected server's `ServerDriver::getDocHover` resolves DefinitionInfo and
`DefinitionInfo::getHover` appends all distinct rendered targets. Its active-design
analysis/override implementation and tests are newer source evidence, not proof
that the installed binary narrows every hover to one selected elaboration. The
client must invalidate old responses on selection but cannot promise a single
width when the server returns multiple variants in one fresh response.
