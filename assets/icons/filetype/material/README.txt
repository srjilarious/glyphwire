An alternate file-type icon theme for glyphwire's canonical file/* names.
Select it with `icon_theme = "material"` in host.conf; glyphwire-host then
loads this set under `file/<name>` (and the alias `oxygen/<name>`)
instead of the default Oxygen set.

The Material Icon Theme (the VS Code file-icon set by Material
Extensions), rasterized from SVG to 48x48 RGBA PNG by
scripts/fetch-icon-themes.sh from:

  https://github.com/material-extensions/vscode-material-icon-theme  (icons/<name>.svg)

License: MIT, see LICENSE.txt in this directory.

Material has no coarse "file type bucket" set the way a desktop icon
theme does, so several canonical names map onto its nearest concrete
icon:

  folder          <- folder-base
  folder-open     <- folder-base   (Material has no distinct open folder)
  home            <- folder-home
  file            <- document
  text            <- document
  code            <- console
  web             <- html
  image           <- image
  audio           <- audio
  video           <- video
  archive         <- zip
  package         <- zip
  pdf             <- pdf
  document        <- word
  spreadsheet     <- table
  presentation    <- powerpoint
  executable      <- exe
  unknown         <- document
  drive           <- disc
  media-optical   <- disc
