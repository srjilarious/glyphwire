# zmd (vendored)

This directory is a vendored, modified copy of [zmd](https://github.com/jetzig-framework/zmd),
a Markdown-to-HTML parser written in pure Zig with no dependencies, originally
built for the [Jetzig](https://github.com/jetzig-framework/jetzig) web framework.

- **Upstream:** https://github.com/jetzig-framework/zmd
- **License:** MIT (per upstream repository)
- **Vendored:** 2026-03-30, from upstream's `main` branch, replacing a
  `build.zig.zon` URL dependency (commit `5a7be1250`). Vendored so zkdocs
  could carry local fixes and extensions upstream doesn't have, without
  waiting on or maintaining a fork as a separate package.

None of the files here are unmodified upstream source — treat this as a fork,
not a pristine copy. If upstream zmd fixes any of the same issues independently,
diff before re-vendoring rather than overwriting.

## Changes made since vendoring

**Initial vendor commit (`5a7be1250`):**
- `Node.zig`: `.code`/`.block` nodes no longer pre-HTML-escape their content
  before handing it to the formatter — formatters are now responsible for
  escaping, consistent with every other node type. (Let zkdocs delete two
  workaround functions in `markdown.zig` that existed only to undo this.)
- `Ast.zig`: added `stripBlock()`, which strips only the leading newline
  after a fence line instead of trimming all leading whitespace — preserves
  intentional leading indentation on the first line of a code block.
- `Formatters.zig`: the image handler now emits `alt=""` instead of
  `title=""`, since `node.title` holds the bracket text (the alt text), not
  a tooltip.

**Native GFM table support (`7a652ae`):**
- `tokens.zig`: added `ElementType.table` and the `Table` element constant.
- `Ast.zig`: tables are detected via custom lookahead in `firstToken`
  (`matchTableEnd`/`isTableSeparatorLine`) rather than the generic
  syntax-matching `elements` table, since a table's extent depends on
  multi-line lookahead, not a fixed close delimiter. `parseTable` renders
  the whole block (header + separator + body rows) directly to HTML,
  mirroring how `parseBlock` already handles fenced code. Cell content is
  parsed through a *nested* `Ast`/`Node.toHtml` pass (`appendCellHtml`), so
  cells get full inline support (code spans, links, bold, italic) instead of
  being treated as opaque text — `escapedCode` patches the one gap that left
  (zmd's default `code` formatter doesn't escape HTML, since it assumes a
  caller-supplied override handles that, as zkdocs's own top-level `codeFmt`
  does; table cells needed the same treatment).
- `Formatters.zig`: added the `table` handler field and `Default.table`.
- `Node.zig`: `.table` nodes are now handled alongside `.code`/`.block` in
  the content-writing switch in `toHtml`.

Because table detection sits inside the same tokenizer logic that already
refuses to scan for new tokens while inside a fenced code block, tables
inherited fence-awareness for free — no separate tracking needed, unlike
zkdocs's admonition extraction (still a pre-processing pass in
`../markdown.zig`, since admonitions have a recursively-rendered body zmd
has no native concept of).

## glyphwire changes

Copied from zkdocs (`src/zmd/`, at zkdocs `72a0f20`) into glyphwire on
2026-09-17 for `gwmd`, the glyphwire Markdown reader. The HTML path above is
untouched. Added alongside it:

- `Document.zig`: a line-based block parser producing a structured tree
  instead of HTML -- headings (ATX and setext) with GitHub-style anchor
  slugs, paragraphs, fenced and indented code, block quotes, nested bullet
  and ordered lists with GFM task items, thematic breaks, GFM tables with
  column alignment, and reference definitions. YAML front matter and HTML
  comments are skipped. zmd's flat token stream has no way to express
  containers, so this sits beside `Ast` rather than inside it.
- `Inline.zig`: a recursive-descent inline parser producing styled *runs*
  (text + bold/italic/code/strike + an optional link index) rather than
  markup. It follows CommonMark's flanking rules, which `Ast`'s inline
  handling doesn't: `Ast` splits `[![alt](a.png)](url)` apart, drops the
  bold from `**bold [link](x)**`, and italicizes `snake_case_name`.
- `zmd.zig`: exports `Document` and `Inline`.
