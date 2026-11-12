import QtQuick
import Quickshell
import Quickshell.Io
import "ColorUtils.js" as CU

// Headless rotator. Every N minutes it picks a new wallpaper at random:
//
//   ~/.config/omarchy/chameleon/  (the gallery) holds images? -> rotate those
//   gallery empty, theme-match off -> omarchy-theme-bg-next (current theme)
//   gallery empty, theme-match on  -> rotate every saved theme background
//
// With theme-match on, each new wallpaper is fed through ImageMagick, a
// palette is derived (ColorUtils.js) and written as the user theme
// "chameleon", then `omarchy-theme-set chameleon` retints the whole system.
// Settings persist in one JSON file this service is the sole writer of.
Item {
  id: root

  property var shell: null
  property var settings: ({})

  readonly property string pluginId: "io.github.alexdont.chameleon"
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/omarchy/" + pluginId
  readonly property string settingsFile: stateDir + "/settings.json"
  readonly property string galleryDir: home + "/.config/omarchy/chameleon"

  // Persisted settings (defaults double as the schema).
  property int intervalMinutes: 60
  property bool themeMatch: false
  property string modePref: "auto"
  property bool paused: false
  property double lastRotatedAt: 0
  // Basenames shown in the current shuffle cycle; resets when the pool is
  // exhausted so every image appears once before any repeats.
  property var seenList: []

  property bool loaded: false
  property bool busy: false
  property string lastError: ""

  // Heartbeat for countdowns in the widget/overlay.
  property double nowMs: Date.now()
  readonly property double dueInMs: Math.max(0, lastRotatedAt + intervalMinutes * 60000 - nowMs)

  function dueLabel() {
    if (paused) return "paused"
    if (busy) return "changing…"
    var mins = Math.ceil(root.dueInMs / 60000)
    if (mins >= 120) return "next in " + Math.round(mins / 60) + "h"
    if (mins > 60) return "next in 1h " + (mins - 60) + "m"
    return "next in " + mins + "m"
  }

  // ---- settings persistence (mktemp+mv, symlink-safe like the limiter) ----

  function loadSettings() { if (!loadProc.running) loadProc.running = true }

  function applyLoaded(raw) {
    try {
      var s = JSON.parse(raw)
      var iv = parseInt(s.intervalMinutes, 10)
      if (iv >= 5 && iv <= 10080) root.intervalMinutes = iv
      root.themeMatch = s.themeMatch === true
      if (s.modePref === "dark" || s.modePref === "light" || s.modePref === "auto") root.modePref = s.modePref
      root.paused = s.paused === true
      var last = Number(s.lastRotatedAt)
      if (isFinite(last) && last > 0 && last <= Date.now()) root.lastRotatedAt = last
      if (Array.isArray(s.seen))
        root.seenList = s.seen.filter(function(x) {
          return typeof x === "string" && x.length > 0 && x.length <= 200
        }).slice(0, 1000)
    } catch (e) { /* first run or corrupt file: keep defaults */ }
    if (root.lastRotatedAt === 0) root.lastRotatedAt = Date.now()
    root.loaded = true
    root.saveSettings()
  }

  property bool savePending: false
  function saveSettings() {
    if (!root.loaded) return
    if (saveProc.running) { root.savePending = true; return }
    saveProc.command = ["sh", "-c",
      'd="${1%/*}"; mkdir -p "$d" 2>/dev/null || exit 0; ' +
      'tmp=$(mktemp "$d/.settings-XXXXXX") || exit 0; ' +
      'printf "%s" "$2" > "$tmp" && mv -f "$tmp" "$1" || rm -f "$tmp"',
      "sh", root.settingsFile,
      JSON.stringify({
        intervalMinutes: root.intervalMinutes,
        themeMatch: root.themeMatch,
        modePref: root.modePref,
        paused: root.paused,
        lastRotatedAt: root.lastRotatedAt,
        seen: root.seenList
      })]
    saveProc.running = true
  }

  function setInterval(mins) {
    mins = parseInt(mins, 10)
    if (isNaN(mins) || mins < 5 || mins > 10080) return
    root.intervalMinutes = mins
    root.saveSettings()
  }

  function setThemeMatch(on) { root.themeMatch = on === true; root.saveSettings() }
  function setPaused(on) { root.paused = on === true; root.saveSettings() }

  function setModePref(pref) {
    if (pref !== "auto" && pref !== "dark" && pref !== "light") return
    if (root.modePref === pref) return
    root.modePref = pref
    root.saveSettings()
    // Retint the running theme right away so the toggle feels live.
    if (root.themeMatch && !root.busy) reapplyProc.running = true
  }

  // The image an in-flight apply will show; committed to seenList only once
  // the apply succeeds, so a failed one stays eligible for this cycle.
  property string pendingSeen: ""

  function markRotated() {
    if (root.pendingSeen !== "" && root.pendingSeen.length <= 200) {
      if (root.seenList.indexOf(root.pendingSeen) === -1) {
        var l = root.seenList.slice()
        l.push(root.pendingSeen)
        root.seenList = l.slice(-1000)
      }
      root.pendingSeen = ""
    }
    root.lastRotatedAt = Date.now()
    root.nowMs = Date.now()
    root.saveSettings()
  }

  // Pool entries not yet shown this cycle, the on-screen one excluded.
  // Matching is by basename: crops and theme staging keep the source name.
  function unseenIn(pool, curBase) {
    var out = []
    for (var i = 0; i < pool.length; i++) {
      var b = pool[i].slice(pool[i].lastIndexOf("/") + 1)
      if (b !== curBase && root.seenList.indexOf(b) === -1) out.push(pool[i])
    }
    return out
  }

  // ---- rotation -----------------------------------------------------------

  function rotateNow() { root.rotate() }

  // Jump straight to one image (from the switcher, scripts, or IPC),
  // still generating a matching theme when theme-match is on.
  function setWallpaper(path) {
    path = String(path || "").trim()
    if (root.busy || !path) return
    root.busy = true
    root.lastError = ""
    root.internalApply(path)
  }

  // Fit pass before applying: an image whose aspect strays more than ~8%
  // from the display gets a display-shaped window cropped out of it at a
  // RANDOM offset — vertical pan for portraits, horizontal for ultrawides —
  // so repeated rotations eventually show the whole picture instead of the
  // renderer's fixed center crop. The crop keeps the source basename (under
  // $stateDir/crops) so rotation-order matching keeps working; the palette
  // is then derived from the crop, i.e. from what is actually on screen.
  function internalApply(path) {
    root.pendingSeen = path.slice(path.lastIndexOf("/") + 1)
    var scr = Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    prepProc.srcPath = path
    prepProc.command = ["bash", "-c",
      '{\n' +
      'img="$1"; sw="$2"; sh="$3"; cdir="$4"\n' +
      'fallback() { printf "%s" "$img"; exit 0; }\n' +
      '[[ -f $img && $sw -gt 0 && $sh -gt 0 ]] || fallback\n' +
      'case "${img,,}" in *.gif) fallback ;; esac\n' +
      'read -r iw ih < <(magick identify -format "%w %h\\n" "${img}[0]" 2>/dev/null)\n' +
      '[[ ${iw:-0} -gt 0 && ${ih:-0} -gt 0 ]] || fallback\n' +
      'ra=$(( iw * 1000 / ih )); rd=$(( sw * 1000 / sh ))\n' +
      'd=$(( ra > rd ? ra - rd : rd - ra ))\n' +
      '(( d * 100 > rd * 8 )) || fallback\n' +
      'mkdir -p "$cdir"\n' +
      'out="$cdir/${img##*/}"\n' +
      'if (( ra < rd )); then\n' +
      '  cw=$iw; ch=$(( iw * sh / sw )); (( ch <= ih )) || ch=$ih\n' +
      '  max=$(( ih - ch )); x=0; y=$(( RANDOM * max / 32767 ))\n' +
      'else\n' +
      '  ch=$ih; cw=$(( ih * sw / sh )); (( cw <= iw )) || cw=$iw\n' +
      '  max=$(( iw - cw )); y=0; x=$(( RANDOM * max / 32767 ))\n' +
      'fi\n' +
      'magick "${img}[0]" -crop "${cw}x${ch}+${x}+${y}" +repage -quality 97 "$out" 2>/dev/null && printf "%s" "$out" || fallback\n' +
      '} | head -c 4096',
      "bash", path, String(scr ? scr.width : 0), String(scr ? scr.height : 0),
      root.stateDir + "/crops"]
    prepProc.running = true
  }

  function continueApply(path) {
    if (root.themeMatch) {
      histProc.imagePath = path
      histProc.command = ["bash", "-c",
        'set -o pipefail; magick "$1" -resize "100x100!" -colors 12 -depth 8 -format "%c" histogram:info:- | head -c 65536',
        "bash", path]
      histProc.running = true
    } else {
      Quickshell.execDetached(["omarchy-theme-bg-set", path])
      root.markRotated()
      root.finish("")
    }
  }

  function rotate() {
    if (root.busy || probeProc.running) return
    root.busy = true
    root.lastError = ""
    probeProc.running = true
  }

  function finish(err) {
    if (err) {
      root.pendingSeen = ""
      root.lastError = err
      Quickshell.execDetached(["omarchy-notification-send", "-e", "-u", "critical",
        "Chameleon", err])
    }
    root.busy = false
  }

  function parseProbe(raw) {
    var current = "", own = [], all = []
    var lines = raw.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line.indexOf("current=") === 0) current = line.slice(8).trim()
      else if (line.indexOf("own=") === 0) own.push(line.slice(4))
      else if (line.indexOf("all=") === 0) all.push(line.slice(4))
    }

    var pool = own.length > 0 ? own : (root.themeMatch ? all : null)

    if (!pool || pool.length === 0) {
      if (root.themeMatch) { root.finish("No saved backgrounds found to rotate"); return }
      // No gallery of our own: let Omarchy cycle the current theme's set.
      Quickshell.execDetached(["omarchy-theme-bg-next"])
      root.markRotated()
      root.finish("")
      return
    }

    // Shuffle cycle: pick at random among the pool images not yet shown this
    // cycle, so every image appears once before anything repeats; when the
    // pool is exhausted, a fresh cycle starts (still skipping the one up now).
    var curBase = current.slice(current.lastIndexOf("/") + 1)
    var candidates = root.unseenIn(pool, curBase)
    if (candidates.length === 0) {
      root.seenList = []
      root.saveSettings()
      candidates = root.unseenIn(pool, curBase)
    }

    if (candidates.length === 0) {
      // The pool holds nothing but the image already on screen.
      if (root.themeMatch && pool.length > 0) { root.internalApply(pool[0]); return }
      root.markRotated()
      root.finish("")
      return
    }

    root.internalApply(candidates[Math.floor(Math.random() * candidates.length)])
  }

  function applyGenerated(histText, imagePath) {
    var palette = CU.buildPalette(CU.parseHistogram(histText), root.modePref)
    if (!palette) {
      // Could not read the image's colors; at least still set the wallpaper.
      Quickshell.execDetached(["omarchy-theme-bg-set", imagePath])
      root.markRotated()
      root.finish("Could not derive a palette — set the wallpaper only")
      return
    }
    applyProc.command = ["bash", "-c",
      'set -e\n' +
      'dir="$HOME/.config/omarchy/themes/chameleon"\n' +
      'mkdir -p "$dir/backgrounds"\n' +
      'printf "%s" "$1" > "$dir/colors.toml"\n' +
      'find "$dir/backgrounds" -maxdepth 1 \\( -type l -o -type f \\) -delete\n' +
      // omarchy-theme-set only recognizes a fixed extension list when it picks
      // the theme background; formats outside it (avif) get a .jpg-suffixed
      // link name — Qt picks the decoder by content, not name.
      'name="${2##*/}"\n' +
      'case "${name,,}" in *.jpg|*.jpeg|*.png|*.gif|*.bmp|*.webp) ;; *) name="$name.jpg" ;; esac\n' +
      'ln -nsf "$2" "$dir/backgrounds/$name"\n' +
      'omarchy-theme-set chameleon',
      "bash", CU.toToml(palette), imagePath]
    applyProc.running = true
  }

  // Visual picker: Omarchy's native thumbnail grid (omarchy-menu-images)
  // over whatever Chameleon would rotate, feeding the choice back through
  // setWallpaper so theme-match still applies.
  function openPicker() {
    if (pickerProc.running || root.busy) return
    pickerProc.command = ["bash", "-c",
      'cur=$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null)\n' +
      'gal="$HOME/.config/omarchy/chameleon"\n' +
      'has_imgs() { find -L "$1" -maxdepth 1 -type f \\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" -o -iname "*.bmp" -o -iname "*.avif" \\) 2>/dev/null | grep -q .; }\n' +
      'dirs=()\n' +
      'if has_imgs "$gal"; then\n' +
      '  dirs=("$gal")\n' +
      'elif [[ "$1" == "1" ]]; then\n' +
      '  for d in "${OMARCHY_PATH:-/usr/share/omarchy}"/themes/*/backgrounds "$HOME/.config/omarchy/themes"/*/backgrounds "$HOME/.config/omarchy/backgrounds"/*/; do\n' +
      '    [[ $d == */themes/chameleon/* || $d == */backgrounds/chameleon/* ]] && continue\n' +
      '    [[ -d $d ]] && dirs+=("$d")\n' +
      '  done\n' +
      'else\n' +
      '  theme_name=$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null)\n' +
      '  dirs=("$HOME/.local/state/omarchy/current/theme/backgrounds" "$HOME/.config/omarchy/backgrounds/$theme_name")\n' +
      'fi\n' +
      '(( ${#dirs[@]} > 0 )) && omarchy-menu-images --selected "$cur" --show-labels "${dirs[@]}" | head -c 4096',
      "bash", root.themeMatch ? "1" : "0"]
    pickerProc.running = true
  }

  function openGallery() {
    Quickshell.execDetached(["sh", "-c",
      'mkdir -p "$1" && setsid xdg-open "$1" >/dev/null 2>&1 &', "sh", root.galleryDir])
  }

  function toggleOverlay() {
    Quickshell.execDetached(["omarchy-shell", "shell", "toggle", root.pluginId, "{}"])
  }

  Component.onCompleted: loadSettings()

  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: {
      root.nowMs = Date.now()
      if (!root.loaded || root.paused || root.busy) return
      if (root.nowMs - root.lastRotatedAt >= root.intervalMinutes * 60000) root.rotate()
    }
  }

  // Bounded, descriptor-safe settings read: ONE descriptor opened with
  // O_NOFOLLOW (a symlink can't redirect the read) and O_NONBLOCK (a planted
  // FIFO can't block us), fstat'd as a regular file, and the capped bytes
  // read from that same descriptor before any parsing. The path is passed
  // positionally as argv. Real settings are a few KB (the shuffle list is
  // capped at 1000 names of <= 200 chars). No python3 -> no bytes -> defaults.
  Process {
    id: loadProc
    command: ["python3", "-I", "-c",
      "import os,sys,stat\n" +
      "try: fd=os.open(sys.argv[1],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)\n" +
      "except OSError: sys.exit(0)\n" +
      "try:\n" +
      "    if stat.S_ISREG(os.fstat(fd).st_mode): sys.stdout.buffer.write(os.read(fd,262144))\n" +
      "finally: os.close(fd)\n",
      root.settingsFile]
    stdout: StdioCollector {
      onStreamFinished: root.applyLoaded(text.slice(0, 262144))
    }
  }

  Process {
    id: saveProc
    onExited: function(code, status) {
      if (root.savePending) { root.savePending = false; root.saveSettings() }
    }
  }

  // One probe answers everything: the resolved current background, the
  // Chameleon gallery, and (for theme-match) every saved theme background.
  // Output is prefix-tagged and bounded; theme-match's wide sweep skips the
  // generated chameleon theme so its symlink never doubles a pool entry.
  Process {
    id: probeProc
    command: ["sh", "-c",
      // set -f keeps the *.jpg patterns in $imgs literal when it word-splits.
      'set -f; { echo "current=$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null)"; ' +
      'imgs="-iname *.jpg -o -iname *.jpeg -o -iname *.png -o -iname *.webp -o -iname *.bmp -o -iname *.avif"; ' +
      'find -L "$HOME/.config/omarchy/chameleon" -maxdepth 1 -type f \\( $imgs \\) 2>/dev/null | sort | sed "s/^/own=/"; ' +
      'find -L "${OMARCHY_PATH:-/usr/share/omarchy}/themes" "$HOME/.config/omarchy/themes" -maxdepth 3 -path "*/backgrounds/*" -type f \\( $imgs \\) 2>/dev/null | grep -v "/themes/chameleon/" | sort | sed "s/^/all=/"; ' +
      'find -L "$HOME/.config/omarchy/backgrounds" -maxdepth 2 -type f \\( $imgs \\) 2>/dev/null | grep -v "/backgrounds/chameleon/" | sort | sed "s/^/all=/"; ' +
      '} | head -c 131072']
    stdout: StdioCollector {
      onStreamFinished: root.parseProbe(text.slice(0, 131072))
    }
    onExited: function(code, status) {
      if (code !== 0 && root.busy) root.finish("Could not scan for backgrounds (exit " + code + ")")
    }
  }

  Process {
    id: histProc
    property string imagePath: ""
    stdout: StdioCollector {
      onStreamFinished: root.applyGenerated(text.slice(0, 65536), histProc.imagePath)
    }
    onExited: function(code, status) {
      if (code !== 0 && root.busy) root.finish("ImageMagick could not read " + histProc.imagePath.slice(histProc.imagePath.lastIndexOf("/") + 1))
    }
  }

  Process {
    id: prepProc
    property string srcPath: ""
    stdout: StdioCollector {
      onStreamFinished: {
        var p = String(text || "").slice(0, 4096).trim()
        root.continueApply(p !== "" ? p : prepProc.srcPath)
      }
    }
  }

  // Re-applies the currently displayed background (after a mode-preference
  // change) so the new mode shows without advancing the rotation.
  Process {
    id: reapplyProc
    command: ["sh", "-c", 'readlink -f "$1" 2>/dev/null | head -c 4096',
      "sh", root.home + "/.local/state/omarchy/current/background"]
    stdout: StdioCollector {
      onStreamFinished: {
        var p = String(text || "").slice(0, 4096).trim()
        if (p !== "") root.setWallpaper(p)
      }
    }
  }

  Process {
    id: pickerProc
    stdout: StdioCollector {
      onStreamFinished: {
        var picked = String(text || "").slice(0, 4096).trim()
        if (picked !== "") root.setWallpaper(picked)
      }
    }
  }

  Process {
    id: applyProc
    onExited: function(code, status) {
      if (code === 0) { root.markRotated(); root.finish("") }
      else root.finish("Theme generation failed (exit " + code + ")")
    }
  }

  // Bindable from Hyprland or scripts: omarchy-shell chameleon rotate
  IpcHandler {
    target: "chameleon"
    function rotate(): void { root.rotateNow() }
    function pause(): void { root.setPaused(true) }
    function resume(): void { root.setPaused(false) }
    function match(on: bool): void { root.setThemeMatch(on) }
    function mode(pref: string): void { root.setModePref(pref) }
    function set(path: string): void { root.setWallpaper(path) }
    function picker(): void { root.openPicker() }
    function status(): string {
      return JSON.stringify({
        intervalMinutes: root.intervalMinutes, themeMatch: root.themeMatch,
        modePref: root.modePref, paused: root.paused, busy: root.busy,
        lastRotatedAt: root.lastRotatedAt, dueInMs: root.dueInMs,
        lastError: root.lastError
      })
    }
  }
}
