glyphwire's Linux-distribution logos, used by glyphwire-shell prompt
templates ({icon:distro/arch} and friends -- see shell/prompt_template.zig).
glyphwire-host scans assets/icons/ at startup and registers every .png
under its path minus the extension, so these resolve as distro/arch,
distro/tux, and so on.

These are the Devicon icon set ("-original" variants, the brand-coloured
logos), rasterized from SVG to 48x48 RGBA PNG by scripts/fetch-devicons.sh:

  https://github.com/devicons/devicon (icons/<name>/<name>-original.svg)

Files here (name -> devicon icon):
  arch.png          archlinux
  tux.png           linux
  debian.png        debian
  fedora.png        fedora
  ubuntu.png        ubuntu
  centos.png        centos
  redhat.png        redhat
  gentoo.png        gentoo
  nixos.png         nixos
  raspberrypi.png   raspberrypi

Re-run scripts/fetch-devicons.sh to refetch or to add more (append a
fetch_devicon line for the new logo). draw_icon scales an icon to fit its
cell aspect-correct, so the 48x48 size is not load-bearing -- it's just a
bit of headroom over the old 32x32 hand-drawn set for the icon atlas.

License: MIT, see DEVICON-LICENSE.txt in this directory (copied verbatim
from the devicons/devicon repo).
