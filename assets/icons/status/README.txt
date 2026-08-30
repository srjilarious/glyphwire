Status glyphs for a configured glyphwire-shell prompt. glyphwire-host
scans assets/icons/ at startup and registers every .png by its path
under that directory minus the extension, so these are `status/error`
and `status/slow` -- meant for `{icon:status/error}` in a
`when = "error"` powerline segment and `{icon:status/slow}` in a
`when = "slow"` one (see decisions.md's Shell section).

32x32 PNGs from the KDE Oxygen icon theme (https://github.com/KDE/oxygen-icons),
same source and license as ../oxygen/ -- see ../oxygen/README.txt and
../oxygen/OXYGEN-LICENSE.txt (GNU LGPL v3, with that file's section 5 GUI
exception). Normalized to 8-bit RGBA on import (chronometer ships 16-bit).

Files here (name -> upstream icon):
  error.png            actions/edit-delete.png   (a bare red cross)
  slow.png             actions/chronometer.png   (a stopwatch)
