An alternate file-type icon theme for glyphwire's canonical file/* names.
Select it with `icon_theme = "papirus"` in host.conf; glyphwire-host then
loads this set under `file/<name>` (and the alias `oxygen/<name>`)
instead of the default Oxygen set.

The Papirus icon theme, rasterized from SVG to 48x48 RGBA PNG by
scripts/fetch-icon-themes.sh from:

  https://github.com/PapirusDevelopmentTeam/papirus-icon-theme  (Papirus/48x48/)

License: GPL-3.0, see LICENSE.txt in this directory.

Papirus stores many icons as relative symlinks (colour variants, mime
aliases); raw.githubusercontent.com hands those back as a target path,
so the fetch script follows them a few hops to the real SVG.

Canonical name -> upstream icon (before symlink resolution):
  folder          <- places/folder.svg
  folder-open     <- places/folder-open.svg
  home            <- places/user-home.svg
  file            <- mimetypes/text-x-generic.svg
  text            <- mimetypes/text-plain.svg
  code            <- mimetypes/application-x-shellscript.svg
  web             <- mimetypes/text-html.svg
  image           <- mimetypes/image-x-generic.svg
  audio           <- mimetypes/audio-x-generic.svg
  video           <- mimetypes/video-x-generic.svg
  archive         <- mimetypes/application-x-archive.svg
  package         <- mimetypes/package-x-generic.svg
  pdf             <- mimetypes/application-pdf.svg
  document        <- mimetypes/x-office-document.svg
  spreadsheet     <- mimetypes/x-office-spreadsheet.svg
  presentation    <- mimetypes/x-office-presentation.svg
  executable      <- mimetypes/application-x-executable.svg
  unknown         <- mimetypes/unknown.svg
  drive           <- devices/drive-harddisk.svg
  media-optical   <- devices/media-optical.svg
