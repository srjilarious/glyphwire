# Third-party code and assets

Everything listed here keeps its own license, unchanged. Nothing in this
file is covered by [`LICENSE.md`](LICENSE.md)'s three-way split, and files
in these directories carry no glyphwire SPDX header.

## Build dependencies

Fetched by the Zig package manager (see `build.zig.zon`) or vendored under
`libs/` and `host_eng/libs/`.

| Dependency | License | Used by |
|---|---|---|
| [SDL3](https://github.com/libsdl-org/SDL) (via `allyourcodebase/SDL`) | Zlib | `host_eng` |
| [zopengl](https://github.com/srjilarious/zopengl) | MIT | `host_eng` |
| [zmath](https://github.com/srjilarious/zmath) | MIT | `host_eng` |
| [zstbi](https://github.com/srjilarious/zstbi) | MIT | `host_eng` |
| `host_eng/libs/stb_truetype` ([stb](https://github.com/nothings/stb)) | Public domain (or MIT) | `host_eng` |
| [ziglua](https://github.com/natecraddock/ziglua) — `libs/ziglua` | MIT | `gw-shell`, `gmux`, `gw-ls`, `zoe` |
| [Lua 5.3](https://www.lua.org/) | MIT | as above, via ziglua |
| [zig-tree-sitter + libtree-sitter](https://github.com/tree-sitter/tree-sitter) | MIT | `zoe` |
| [zargunaught](https://github.com/srjilarious/zargunaught) | MIT | `gw-ls`, `gw-view`, `gw-read`, `gwmd` |
| `md/libs/zmd` ([zmd](https://github.com/jetzig-framework/zmd), via zkdocs's fork) | MIT | `gwmd` — modified; see `md/libs/zmd/README.md` |
| [testz](https://github.com/srjilarious/testz) | MIT | test runner |

All are permissive and compatible with both MPL-2.0 and GPL-3.0-or-later.

### Tree-sitter grammars

Compiled to standalone `parser.so` files that `zoe` `dlopen`s at runtime;
never linked into a glyphwire binary.

| Grammar | License |
|---|---|
| `tree-sitter-zig`, `tree-sitter-json`, `tree-sitter-python`, `tree-sitter-toml`, `tree-sitter-markdown` | MIT |
| `vendor/grammars/c` (`tree-sitter-c`) | MIT |

## Bundled assets (`assets/`)

Installed to `share/glyphwire/assets` and read at runtime by the host. Data
files, not linked code — but the copyleft ones below still carry their own
terms wherever the package goes.

### Fonts

| File | Source | License |
|---|---|---|
| `JetBrainsMono-Regular.ttf` | [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) | SIL OFL 1.1 (`JetBrainsMono-LICENSE.txt`) |
| `NotoSansCJK-Regular.ttc` | [Noto CJK](https://github.com/notofonts/noto-cjk) | SIL OFL 1.1 (`NotoSansCJK-LICENSE.txt`) |
| `PowerlineSymbols-subset.ttf` | [powerline/powerline](https://github.com/powerline/powerline) | MIT — **no license file is currently bundled; see Open items** |

### Icons

| Directory | Source | License |
|---|---|---|
| `icons/filetype/oxygen/` | KDE Oxygen — **the default theme** | **LGPL-3.0** (`LICENSE.txt`, `README.txt`) |
| `icons/filetype/papirus/` | Papirus | **GPL-3.0** (`LICENSE.txt`, `README.txt`) |
| `icons/filetype/material/` | Material Icon Theme | MIT (`LICENSE.txt`, `README.txt`) |
| `icons/dev/` | Devicon, Lobe Icons | MIT (`DEVICON-LICENSE.txt`, `LOBE-ICONS-LICENSE.txt`) |
| `icons/distro/` | Devicon | MIT (`DEVICON-LICENSE.txt`) |
| `icons/status/` | KDE Oxygen | **LGPL-3.0** (`README.txt`) |
| `icons/box/` | Generated for this project with Pillow | MPL-2.0, as project assets |
| `icons/dialog/`, `icons/notify/` | Undocumented — see Open items | Unconfirmed |

`scripts/fetch-oxygen.sh`, `scripts/fetch-devicons.sh` and
`scripts/fetch-icon-themes.sh` are the provenance record for the fetched
sets; they refetch each theme from upstream.

## Copyleft icons and embedding the host

This is the one place a copyleft obligation reaches something otherwise
MPL. `glyphwire` (the host) is MPL-2.0 and can be embedded unmodified in a
product under any license — but the icon theme it loads by default,
Oxygen, is LGPL-3.0, and the Papirus theme shipped beside it is GPL-3.0.

The host reads these as PNG files at runtime; it does not link them, and it
does not depend on any particular theme. A product that wants no copyleft
assets in its package should:

1. ship only `assets/icons/filetype/material/` (MIT) from the file-type
   themes, and
2. set `icon_theme = "material"` in `host.conf.lua`.

`assets/icons/status/` is Oxygen too, and is only referenced by
`gw-shell` powerline prompt segments (itself GPL-3.0-or-later), so it can
be dropped along with the shell.

## Open items

These are gaps in this inventory, not known violations. They should be
closed before a public release.

- **`assets/PowerlineSymbols-subset.ttf`** ships with no bundled license
  file. Upstream powerline is MIT; add `PowerlineSymbols-LICENSE.txt`
  alongside the other two font licenses.
- **`assets/icons/dialog/` and `assets/icons/notify/`** have no `README.txt`
  recording their origin, unlike every other icon directory. `dialog/` is a
  9-slice gradient panel and looks generated the same way `box/` was; the
  three 32x32 `notify/` glyphs match the size and era of the Oxygen-sourced
  `status/` set. Confirm each and add a `README.txt` — if `notify/` is
  Oxygen, it is LGPL-3.0 and belongs in the copyleft list above.
