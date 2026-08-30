glyphwire's developer-tool / programming-language logos. glyphwire-host
scans assets/icons/ at startup and registers every .png under its path
minus the extension, so these resolve as dev/zig, dev/elixir, dev/vscode,
and so on.

glyphwire-ls maps a file extension (or a well-known directory name like
.vscode / .claude / .git) to one of these; see ls/icons.zig. Anything
without a dev/ logo falls back to the coarser oxygen/ file-type buckets.

Almost all are the Devicon set ("-original" where it exists, else
"-plain"), rasterized from SVG to 48x48 RGBA PNG by
scripts/fetch-devicons.sh:

  https://github.com/devicons/devicon (icons/<name>/<name>-*.svg)

A handful of Devicon "-original" logos are a solid near-black glyph
(rust, deno, github, markdown, latex, crystal); since glyphwire-ls draws
icons on a near-black row background, fetch-devicons.sh repaints their
opaque pixels to a light grey (alpha preserved) after rasterizing.

claude.png and claudecode.png are not in Devicon -- they come from
LobeHub's icon set ("-color" variants):

  https://github.com/lobehub/lobe-icons (packages/static-svg/icons)

Re-run scripts/fetch-devicons.sh to refetch or to add more (append a
fetch_devicon / fetch_lobe line, then wire the extension in ls/icons.zig).

License: MIT. See DEVICON-LICENSE.txt (devicons/devicon) and
LOBE-ICONS-LICENSE.txt (lobehub/lobe-icons) in this directory, each
copied verbatim from its upstream repo.
