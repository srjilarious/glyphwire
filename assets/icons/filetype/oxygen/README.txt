glyphwire's default file-type icon theme -- the set behind the canonical
`file/*` icon names (folder, file, image, pdf, ...) that glyphwire-ls
draws with. host.conf's `icon_theme` picks between this and the sibling
`papirus/` / `material/` themes; glyphwire-host loads the chosen one under
both `file/<name>` and the back-compat alias `oxygen/<name>`.

The KDE Oxygen icon theme, at its native 48x48 size, fetched by
scripts/fetch-oxygen.sh from:

  https://github.com/pasnox/oxygen-icons-png  (48x48/{places,mimetypes,devices,status})

pasnox/oxygen-icons-png is a dereferenced mirror of https://github.com/KDE/oxygen-icons
-- the upstream KDE repo stores most of these as symlinks GitHub's raw
file server doesn't follow.

draw_icon scales an icon down to fit its box, aspect-correct -- see
decisions.md's Icon section -- so 48x48 is just the source size, not a
requirement.

License: GNU LGPL version 3, see LICENSE.txt in this directory (copied
verbatim from the KDE/oxygen-icons repo's COPYING file). Per that file,
source format for this artwork is defined as SVG or PNG, and section 5's
GUI exception covers using these icons in an application like glyphwire
without further copyleft obligations on glyphwire itself.

Canonical name -> upstream icon:
  folder.png          places/folder.png
  folder-open.png     status/folder-open.png
  home.png            places/user-home.png
  file.png            mimetypes/text-x-generic.png
  text.png            mimetypes/text-plain.png
  code.png            mimetypes/application-x-shellscript.png
  web.png             mimetypes/text-html.png
  image.png           mimetypes/image-x-generic.png
  audio.png           mimetypes/audio-x-generic.png
  video.png           mimetypes/video-x-generic.png
  archive.png         mimetypes/application-x-archive.png
  package.png         mimetypes/application-x-rpm.png
  pdf.png             mimetypes/application-pdf.png
  document.png        mimetypes/x-office-document.png
  spreadsheet.png     mimetypes/x-office-spreadsheet.png
  presentation.png    mimetypes/x-office-presentation.png
  executable.png      mimetypes/application-x-executable.png
  unknown.png         mimetypes/unknown.png
  drive.png           devices/drive-harddisk.png
  media-optical.png   devices/media-optical.png
