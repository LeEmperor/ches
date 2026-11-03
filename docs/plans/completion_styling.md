# Completion-specific styling

## Goal

Replace the completion menu's borrowed Insert-mode badge with its own semantic
styles. Candidate, source tag, detail/type string, prefix match and documentation
have separate foregrounds. Selected rows share one subdued background while
retaining element-specific foregrounds. Existing column alignment, clipping,
Unicode display widths and one-cell trailing padding remain intact.

First scope colors the complete detail string as one type/detail element, not
language-specific syntax tokens. Highlight only a real label-prefix match; LSP
filterText may differ from the displayed label. Selection/prefix emphasis does
not change candidate ordering or insertion behavior.

## Configuration API

```ocaml
Completion.set_color ~role:"selected_background" "#283447";
Completion.set_color ~role:"detail" "#b8d7a3";
Completion.set_color ~role:"selected_detail" "#c9e8b4"
```

Supported role names: `background`, `selected_background`, `label`,
`selected_label`, `source`, `selected_source`, `detail`, `selected_detail`,
`match`, `selected_match`, `documentation`. Colors are strict #RRGGBB values.
Omitted roles follow the current theme. Declarations are last-wins, reset with
fresh defaults each config evaluation, and invalid roles/colors reject the entire
configuration. Overrides follow theme previews/switches without recoloring mode
badges, document syntax or unrelated UI.

## Ownership and verification

- Theme worker: theme roles/defaults/override API, screen Style variants and UI
  attribute mapping, dark/light palette checks.
- Rendering worker: independent completion spans, real prefix highlighting,
  override application through screen state/theme lifecycle, rendering tests.
- Config worker: Stdlib setter, snapshot/protocol/cache compatibility and tests.

Existing unrelated edits in screen/terminal_tile.ml and screen/test/test_terminal.ml
are outside this task. No personal config edits or Git mutations. Three agents,
six build jobs each, aggregate limit20. Full build/tests and contrast/render/config
regressions after integration.

## Status

Implemented and validated. Eleven semantic theme roles have derived defaults for
all registered themes and custom Base16 palettes. Selected background uses a
subdued surface/foreground blend. Default foregrounds retain semantic hue while
meeting measured contrast targets across both row states (4.5:1 for labels,
details, matches and documentation; 3:1 for sources). Explicit overrides are exact.

Completion rows now emit independent Label/Source/Detail/Match/Documentation/Padding
spans. Prefix matching uses the original session prefix and only highlights the
displayed label's real prefix; filterText-only matches are not misrepresented.
Combining marks, escaped controls, wide glyphs and clipped columns preserve cell
widths. Documentation padding shares the menu surface, and selected padding shares
the selected background.

`Completion.set_color` records strict canonical RGB overrides in settings and the
bounded v4 helper protocol. Older v2/v3 snapshots default to no overrides. Config
reload validation is atomic, theme registry values remain immutable, and previews,
acceptance, cancellation and CLI theme selection all retain overrides. Removing
them restores theme defaults on reload. Compiled helpers invalidate through the
embedded API/protocol identity.

Full `dune build -j 12 @all` / `dune runtest -j 12` passed, followed by reviewer
theme/UI/config/screen suites and an added escaped-control/combining/clipping
regression. Review found no further production defects. No personal configuration
or unrelated terminal edits were changed, and no staging/commits/pushes occurred.
