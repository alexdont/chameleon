# Chameleon

An [Omarchy](https://omarchy.org) shell plugin that rotates your wallpapers on
a schedule — and, if you opt in, regenerates the entire system theme to match
each new background, like a chameleon changing its colors to its surroundings.

## What it does

- **Scheduled rotation** — changes the wallpaper every 15 minutes to once a
  day (your pick). The schedule survives shell restarts: a daily rotation set
  yesterday still fires today.
- **Your gallery** — drop images into `~/.config/omarchy/chameleon/` and those
  become the rotation, picked shuffle-style: random order, but every image is
  shown once before any repeats (the shown set persists across shell
  restarts). When the folder is empty, Chameleon rotates the current
  theme's own backgrounds (which already match the theme).
- **Theme-match (opt-in)** — with the toggle on, every new wallpaper is fed
  through ImageMagick, a full Omarchy palette is derived from its dominant
  colors, and the generated user theme `chameleon` is applied system-wide:
  bar, terminals, browser, editors — everything `omarchy theme set` retints.
  With the gallery empty, theme-match rotates through every background of
  every saved theme.
- **Mode: Auto / Dark / Light** — Auto decides dark or light from the
  wallpaper's perceived lightness; the Dark and Light chips force it for
  images Auto gets wrong (or by taste). Changing it retints immediately.
- **Random pan for ill-fitting images** — when an image's aspect strays more
  than ~8% from the display's, a display-shaped window is cropped out of it
  at a random offset each rotation (vertical pan for portraits, horizontal
  for ultrawides), so over time the whole picture gets seen instead of the
  renderer's fixed center crop. The palette comes from the visible slice.

## Controls

- **Bar widget** — left-click opens the wallpaper picker (Omarchy's native
  thumbnail grid over your rotation pool; the pick still theme-matches);
  middle-click jumps to a random one; right-click opens settings.
  The glyph dims while rotation is paused.
- **Settings card** — schedule presets, the theme-match toggle, pause,
  choose/rotate-now, and a shortcut to the gallery folder.
  Keys: `W` choose · `R` rotate · `P` pause · `Esc` close.
- **Scripting / keybindings** —
  `omarchy-shell chameleon rotate | picker | set <path> | pause | resume | match true|false | mode auto|dark|light | status`

## How theme generation works

The wallpaper is downscaled and quantized to ~12 dominant color clusters
(`magick -colors 12 histogram:info:`). Weighted luminance decides dark or
light mode; the most chromatic mid-lightness cluster becomes the accent; the
darkest (or lightest) weighty cluster tints the background family; and the
ANSI terminal colors keep their standard hues but carry the wallpaper's
saturation so the terminal reads as the same family as the desktop. The result
is written to `~/.config/omarchy/themes/chameleon/colors.toml` with the
wallpaper symlinked as the theme's only background, then applied with
`omarchy theme set chameleon`.

## Install

Requires Omarchy 4.x (Quattro) with the Quickshell-based shell.

```bash
omarchy plugin add https://github.com/alexdont/chameleon.git --enable
```

Optional keybinding (add to `~/.config/hypr/bindings.lua`):

```lua
o.bind("SUPER + ALT + W", "Next wallpaper", "omarchy-shell chameleon rotate")
```

### Dependencies

Everything it needs ships with Omarchy:

- **ImageMagick** (`magick`) — palette extraction for theme-match and the
  random-pan crops
- **python3** — a small bounded, symlink-safe reader for the settings file
- **AVIF wallpapers (optional)** — need Qt's extra image formats:
  `sudo pacman -S kimageformats`

## State

Settings live in
`~/.local/state/omarchy/io.github.alexdont.chameleon/settings.json`.
Delete the file to reset to defaults (hourly rotation, theme-match off).

## What it writes

Nothing outside its own folders, and nothing system-wide until you opt in:

- `~/.local/state/omarchy/io.github.alexdont.chameleon/` — settings and the
  random-pan crops
- `~/.config/omarchy/chameleon/` — your gallery (created only when you open
  it from the settings card)
- `~/.config/omarchy/themes/chameleon/` — the generated theme, **only with
  theme-match turned on**. Your other themes are never edited; switching to
  any other theme with `omarchy theme set` leaves Chameleon's theme unused.

## Remove

Turn theme-match off (or switch to another theme) first, then:

```bash
omarchy plugin remove io.github.alexdont.chameleon
omarchy theme set tokyo-night   # or any other theme, if "chameleon" is still active
rm -rf ~/.local/state/omarchy/io.github.alexdont.chameleon ~/.config/omarchy/themes/chameleon
```

The gallery at `~/.config/omarchy/chameleon/` holds your own images, so it is
left for you to keep or delete.

## License

MIT — see [LICENSE](LICENSE).
