# Chameleon

An [Omarchy](https://omarchy.org) shell plugin that rotates your wallpapers on
a schedule — and, if you opt in, regenerates the entire system theme to match
each new background, like a chameleon changing its colors to its surroundings.

## What it does

- **Scheduled rotation** — changes the wallpaper every 15 minutes to once a
  day (your pick). The schedule survives shell restarts: a daily rotation set
  yesterday still fires today.
- **Your gallery** — drop images into `~/.config/omarchy/chameleon/` and those
  become the rotation. When the folder is empty, Chameleon rotates the current
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
  middle-click rotates to the next one; right-click opens settings.
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

## Requirements

- Omarchy with the Quickshell-based shell (`omarchy-shell`)
- ImageMagick (`magick`) — preinstalled on Omarchy — for theme-match

## State

Settings live in
`~/.local/state/omarchy/io.github.alexdont.chameleon/settings.json`.
Delete the file to reset to defaults (hourly rotation, theme-match off).
