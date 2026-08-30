glyphwire's default icon registry (see core.zig's default_icon_manifest)
is seeded from the KDE Oxygen icon theme, 32x32 PNGs, pulled from:

  https://github.com/KDE/oxygen-icons (32x32/{places,mimetypes,devices}/*)

Some entries (image, audio, video, spreadsheet, presentation, web) are
pulled dereferenced from https://github.com/pasnox/oxygen-icons-png
instead, since the upstream KDE repo stores those as symlinks GitHub's
raw file server doesn't follow.

Kept at 32x32, the icon theme's native small size. draw_icon scales an
icon to fit its cell, aspect-correct (letterboxed, not stretched) -- see
decisions.md's Icon section -- so unlike draw_image/draw_box there's no
need to pre-shrink these to match any particular cell size.

License: GNU LGPL version 3, see OXYGEN-LICENSE.txt in this directory
(copied verbatim from the KDE/oxygen-icons repo's COPYING file). Per that
file, source format for this artwork is defined as SVG or PNG, and
section 5's GUI exception covers using these icons in an application like
glyphwire without further copyleft obligations on glyphwire itself.

Files here (name -> upstream icon):
  folder.png          places/inode-directory.png
  folder-open.png      places/folder-open.png (via status/)
  home.png              places/user-home.png
  file.png              mimetypes/text-sgml.png
  audio.png             mimetypes/audio-x-generic.png
  image.png             mimetypes/image-x-generic.png
  video.png             mimetypes/video-x-generic.png
  archive.png           mimetypes/application-x-ar.png
  executable.png        mimetypes/application-x-desktop.png
  unknown.png           mimetypes/unknown.png
  drive.png             devices/drive-harddisk.png
  media-optical.png     devices/media-optical.png

  Finer file-type buckets (glyphwire-ls maps an extension to one of
  these; see ls/icons.zig):
  pdf.png               mimetypes/application-pdf.png
  document.png          mimetypes/x-office-document.png
  spreadsheet.png       mimetypes/x-office-spreadsheet.png  (via pasnox)
  presentation.png      mimetypes/x-office-presentation.png (via pasnox)
  text.png              mimetypes/text-plain.png
  code.png              mimetypes/application-x-shellscript.png
  web.png               mimetypes/text-html.png             (via pasnox)
  package.png           mimetypes/application-x-rpm.png
