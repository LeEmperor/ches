# Search highlighting performance

## Report

Searching for `sign` with `/` in a roughly 20,000-line `loader_core.v` file caused significant lag in Ches, while Neovim remained responsive. The query matches common substrings in `signal` and `assign`.

The findings below come from source inspection, not profiling. The original test file was not found in the workspace. Line references describe the implementation at the time of investigation and may shift.

## Ches hot paths

### Highlighting: whole-buffer scan on every frame

In `screen/frame.ml:82–94`, `Frame.render` scans every code-point boundary in the buffer and builds a list of all matches. This happens on each render with an active search, including search-prompt previews, rather than only when the query or text changes.

In `screen/frame.ml:148–155`, the glyph highlight callback calls `List.find_map` on that complete match list, starting at its beginning for every glyph. Characters outside any match traverse the entire list. More matches therefore make even unrelated characters more expensive to render.

In `screen/span.ml:43`, the highlight callback runs before horizontal clipping. Offscreen glyphs on rendered lines also incur the lookup cost.

Approximate worst-case work per frame is **O(B × Q + G × M)**, where B is buffer size, Q is query length, G is the number of glyphs in rendered lines (including horizontally clipped glyphs), and M is the total number of matches in the buffer.

`Text_buffer.to_string` is just a field accessor (`core/text_buffer.ml:78`); its use inside the matching helper does not copy the buffer.

### Navigation: enumerate everything before choosing a match

In `core/editor.ml:479–493`, search builds a list of every code-point boundary, filters it into all matching positions, partitions/reorders those positions by direction, and finally selects the requested occurrence. `/`, `?`, and repeated `n`/`N` navigation therefore do whole-buffer work even when the next match is nearby.

## Neovim reference implementation

The local reference checkout is `../neovim/`.

- **Line-driven highlighting:** `src/nvim/match.c:563`, `prepare_search_hl_line`, prepares matches for a window line. `next_search_hl` at line 384 retains a current match and advances as needed, rather than searching a global match list for every character. `prepare_search_hl` at line 486 adds handling for multiline patterns, including scanning from the window top when necessary. This is not a claim that arbitrary multiline regexes only inspect visible bytes.
- **Early-exit navigation:** `src/nvim/search.c`, `searchit`, searches in the requested direction and stops after the requested number of matches (`:968`), with wrap handling. It does not need to enumerate all matches first to navigate.
- **Input-aware incremental search:** `src/nvim/ex_getln.c:418` postpones incremental search when another input character is waiting. At line 460 it sets a 500 ms deadline for the preview search. `src/nvim/search.c:915` periodically checks for incoming input during that search.
- **Highlighting deadlines:** `src/nvim/match.c:414` checks a time limit; regex execution at line 450 receives that deadline and can report a timeout.

The important distinction is separating navigation from drawing highlights, and bounding the work required to draw a window. The 500 ms preview deadline is a fallback, not a target frame time.

## Suggested implementation order

1. **Restrict highlighting searches to viewport lines.** Preserve matches that overlap viewport boundaries, including horizontally clipped matches and any supported literal queries containing newlines. Searching entire visible lines first is a reasonable initial simplification for ordinary line lengths.
2. **Walk ordered match ranges alongside glyphs.** Avoid restarting a lookup from the beginning for each glyph. Preserve the existing behavior for overlapping matches, current-match styling, and selection precedence.
3. **Use directional, early-exit navigation.** Scan from the cursor and stop after the requested occurrence; wrap when needed. Preserve existing count semantics, including counts exceeding the total number of matches, without allocating a list of every character boundary.
4. **Consider caching and input cancellation afterward.** If caching is useful, invalidate on text/query/case/whole-word changes and account for viewport and current-match changes as appropriate. First remove the unnecessary whole-buffer and per-glyph global-list work.

Keep smart-case/explicit case policies, UTF-8 boundaries, whole-word searches, forward/backward behavior, and wrap messages consistent. Highlighting and navigation currently duplicate matching logic; a shared matcher could help prevent semantic drift.

## Verification for the follow-up

- Reproduce with the original file if available, or a comparable 20,000-line fixture containing many `signal` and `assign` occurrences.
- Measure search-prompt render time separately from committed-search and `n`/`N` navigation time.
- Compare files of increasing size with the same viewport contents: ordinary highlight rendering should no longer scale with matches in unrelated offscreen lines.
- Exercise dense matches, no matches, scrolling, horizontal clipping, overlapping matches, Unicode, smart-case, whole-word searches, and wrap/count behavior.
- Run the existing editor, keymap, and frame tests; add focused regression coverage for changed search semantics or boundary handling.
