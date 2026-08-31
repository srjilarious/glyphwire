An alternate file-type icon theme for glyphwire's canonical file/* names.
Select it with `icon_theme = "papirus"` in host.conf.

*** The icons are not vendored here. *** Run

  scripts/fetch-icon-themes.sh papirus

to populate this directory (20 SVGs from the Papirus icon theme,
rasterized to 48x48 RGBA PNG, plus LICENSE.txt). It also fetches the
GPL-3.0 license text next to them.

Until then, glyphwire-host treats `icon_theme = "papirus"` as "theme has
no icons" and falls back to the default Oxygen set (with a warning). The
fetch is kept as a script rather than a committed asset because it
couldn't run in the environment this feature was built in (only a few
icon-repo hosts were reachable), not because Papirus is unwanted.

Source: https://github.com/PapirusDevelopment/papirus-icon-theme  (GPL-3.0)
  Papirus/64x64/{places,mimetypes,devices}/<name>.svg -- see the `papirus`
  map in scripts/fetch-icon-themes.sh for the canonical-name mapping.
