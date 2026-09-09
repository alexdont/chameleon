// Pure-JS palette math for Chameleon: parse an ImageMagick histogram of a
// wallpaper's dominant colors and derive a full Omarchy colors.toml palette
// from it. No dependencies.
.pragma library

function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v }

function rgbToHsl(r, g, b) {
  r /= 255; g /= 255; b /= 255
  var max = Math.max(r, g, b), min = Math.min(r, g, b)
  var l = (max + min) / 2, h = 0, s = 0
  var d = max - min
  if (d !== 0) {
    s = d / (1 - Math.abs(2 * l - 1))
    if (max === r) h = 60 * (((g - b) / d) % 6)
    else if (max === g) h = 60 * ((b - r) / d + 2)
    else h = 60 * ((r - g) / d + 4)
  }
  if (h < 0) h += 360
  return { h: h, s: s, l: l }
}

function hslToRgb(h, s, l) {
  h = ((h % 360) + 360) % 360; s = clamp(s, 0, 1); l = clamp(l, 0, 1)
  var c = (1 - Math.abs(2 * l - 1)) * s
  var x = c * (1 - Math.abs((h / 60) % 2 - 1))
  var m = l - c / 2
  var i = Math.floor(h / 60)
  var rp = [c, x, 0, 0, x, c][i]
  var gp = [x, c, c, x, 0, 0][i]
  var bp = [0, 0, x, c, c, x][i]
  return { r: (rp + m) * 255, g: (gp + m) * 255, b: (bp + m) * 255 }
}

function toHex(r, g, b) {
  var h = function(v) { return ("0" + Math.round(clamp(v, 0, 255)).toString(16)).slice(-2) }
  return "#" + h(r) + h(g) + h(b)
}

function hex(h, s, l) {
  var rgb = hslToRgb(h, s, l)
  return toHex(rgb.r, rgb.g, rgb.b)
}

function srgbToLinear(c) {
  c = c / 255
  return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
}

function luminance(r, g, b) {
  return 0.2126 * srgbToLinear(r) + 0.7152 * srgbToLinear(g) + 0.0722 * srgbToLinear(b)
}

// ImageMagick `-format %c histogram:info:` lines look like
//   "  1613: (49.3,60.0,66.2) #313C42 srgb(...)" — the hex field is the
// truth; counts weight each cluster. Returns [{count, share, r, g, b}].
function parseHistogram(text) {
  var out = [], total = 0
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length && out.length < 64; i++) {
    var m = lines[i].match(/^\s*(\d+):\s*\([^)]*\)\s*#([0-9a-fA-F]{6})/)
    if (!m) continue
    var count = parseInt(m[1], 10)
    var n = parseInt(m[2], 16)
    if (!(count > 0)) continue
    out.push({ count: count, r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 })
    total += count
  }
  for (var j = 0; j < out.length; j++) out[j].share = total > 0 ? out[j].count / total : 0
  return out
}

// The palette recipe: overall weighted luminance decides dark/light mode,
// the most chromatic mid-lightness cluster becomes the accent, the
// darkest (or lightest) weighty cluster tints the background family, and
// the ANSI colors keep their standard hues but carry the wallpaper's
// saturation so the terminal reads as the same family as the desktop.
function buildPalette(clusters, modePref) {
  if (!clusters || clusters.length === 0) return null

  // Perceptual lightness (CIE L*), averaged PER CLUSTER, not the L* of the
  // averaged light: cube-root first, then weight. A small bright patch (sky
  // glare, one white cloud) then counts as its share of the image instead of
  // dragging the whole mix over the light/dark line. modePref ("dark"/
  // "light") overrides the detection outright.
  var lstar = 0
  for (var i = 0; i < clusters.length; i++) {
    var c = clusters[i]
    var y = luminance(c.r, c.g, c.b)
    lstar += (116 * Math.pow(Math.max(y, 0.0001), 1 / 3) - 16) * c.share
  }
  var dark = modePref === "dark" ? true : modePref === "light" ? false : lstar < 55

  var aH = 215, aS = 0.25, best = -1
  for (var j = 0; j < clusters.length; j++) {
    var hsl = rgbToHsl(clusters[j].r, clusters[j].g, clusters[j].b)
    var score = hsl.s * (1 - Math.abs(hsl.l - 0.55)) * (0.35 + 0.65 * Math.sqrt(clusters[j].share))
    if (score > best) { best = score; aH = hsl.h; aS = hsl.s }
  }
  // A near-grayscale wallpaper keeps a quiet accent instead of neon.
  if (aS < 0.12) aS = 0.18

  // Background tint: group the clusters on the mode's side of mid-lightness
  // into hue FAMILIES (30° bins, achromatic separate) and let the heaviest
  // family win — a sky quantized into four slightly different blues beats
  // the single white cloud cluster that would out-weigh any one of them.
  // Chromatic families get a bias: a colored bar is the point of Chameleon,
  // so gray only wins when it truly dominates.
  var buckets = {}
  for (var k = 0; k < clusters.length; k++) {
    var bhsl = rgbToHsl(clusters[k].r, clusters[k].g, clusters[k].b)
    if (dark ? bhsl.l > 0.45 : bhsl.l < 0.55) continue
    var key = bhsl.s < 0.1 ? "a" : String(Math.floor(((bhsl.h + 15) % 360) / 30))
    var b = buckets[key] || { share: 0, hx: 0, hy: 0, s: 0 }
    var rad = bhsl.h * Math.PI / 180
    b.share += clusters[k].share
    b.hx += Math.cos(rad) * clusters[k].share
    b.hy += Math.sin(rad) * clusters[k].share
    b.s += bhsl.s * clusters[k].share
    buckets[key] = b
  }
  var bestChroma = null, achro = null
  for (var key2 in buckets) {
    if (key2 === "a") { achro = buckets[key2]; continue }
    if (!bestChroma || buckets[key2].share > bestChroma.share) bestChroma = buckets[key2]
  }
  var bH = aH, bS = 0.2
  if (bestChroma && (!achro || bestChroma.share >= achro.share * 0.6)) {
    bH = (Math.atan2(bestChroma.hy, bestChroma.hx) * 180 / Math.PI + 360) % 360
    bS = bestChroma.s / bestChroma.share
  } else if (achro) {
    // A genuinely gray wallpaper keeps a gray bar, faintly tinted by the
    // accent so it still belongs to the image.
    bS = 0.06
  } else {
    // Nothing on the right side of mid-lightness at all: fall back to the
    // most extreme cluster with real weight.
    var pickL = dark ? 2 : -1
    for (var k2 = 0; k2 < clusters.length; k2++) {
      if (clusters[k2].share < 0.02) continue
      var fhsl = rgbToHsl(clusters[k2].r, clusters[k2].g, clusters[k2].b)
      if (dark ? fhsl.l < pickL : fhsl.l > pickL) { pickL = fhsl.l; bH = fhsl.h; bS = fhsl.s }
    }
  }
  bS = Math.min(bS, 0.35)

  var p = { mode: dark ? "dark" : "light" }
  if (dark) {
    p.accent = hex(aH, clamp(aS, 0.35, 0.8), 0.68)
    p.selection = hex(bH, Math.min(bS + 0.05, 0.4), 0.23)
    p.muted = hex(bH, Math.min(bS, 0.15), 0.42)
    p.background = hex(bH, bS, 0.11)
    p.dark_background = hex(bH, bS, 0.08)
    p.darker_background = hex(bH, bS, 0.055)
    p.lighter_background = hex(bH, bS, 0.16)
    p.foreground = hex(bH, 0.15, 0.84)
    p.dark_foreground = hex(bH, 0.10, 0.45)
    p.light_foreground = hex(bH, 0.13, 0.72)
    p.bright_foreground = hex(bH, 0.17, 0.90)
  } else {
    p.accent = hex(aH, clamp(aS, 0.4, 0.85), 0.42)
    p.selection = hex(bH, Math.min(bS + 0.05, 0.4), 0.82)
    p.muted = hex(bH, Math.min(bS, 0.15), 0.6)
    p.background = hex(bH, bS, 0.92)
    p.dark_background = hex(bH, bS, 0.87)
    p.darker_background = hex(bH, bS, 0.83)
    p.lighter_background = hex(bH, bS, 0.95)
    p.foreground = hex(bH, 0.2, 0.28)
    p.dark_foreground = hex(bH, 0.1, 0.55)
    p.light_foreground = hex(bH, 0.15, 0.38)
    p.bright_foreground = hex(bH, 0.25, 0.2)
  }

  var tS = clamp(0.3 + aS * 0.45, 0.35, 0.7)
  var tL = dark ? 0.68 : 0.44
  var bL = dark ? 0.75 : 0.40
  var hues = { red: 358, orange: 25, yellow: 48, green: 115, cyan: 180, blue: 215, magenta: 300 }
  for (var name in hues) {
    p[name] = hex(hues[name], tS, tL)
    if (name !== "orange") p["bright_" + name] = hex(hues[name], tS, bL)
  }
  p.brown = hex(25, clamp(tS * 0.6, 0.25, 0.45), dark ? 0.40 : 0.35)

  return p
}

function toToml(p) {
  return 'mode = "' + p.mode + '"\n\n' +
    'accent = "' + p.accent + '"\n' +
    'selection = "' + p.selection + '"\n' +
    'muted = "' + p.muted + '"\n\n' +
    'background = "' + p.background + '"\n' +
    'dark_background = "' + p.dark_background + '"\n' +
    'darker_background = "' + p.darker_background + '"\n' +
    'lighter_background = "' + p.lighter_background + '"\n\n' +
    'foreground = "' + p.foreground + '"\n' +
    'dark_foreground = "' + p.dark_foreground + '"\n' +
    'light_foreground = "' + p.light_foreground + '"\n' +
    'bright_foreground = "' + p.bright_foreground + '"\n\n' +
    'red = "' + p.red + '"\n' +
    'yellow = "' + p.yellow + '"\n' +
    'orange = "' + p.orange + '"\n' +
    'green = "' + p.green + '"\n' +
    'cyan = "' + p.cyan + '"\n' +
    'blue = "' + p.blue + '"\n' +
    'magenta = "' + p.magenta + '"\n' +
    'brown = "' + p.brown + '"\n\n' +
    'bright_red = "' + p.bright_red + '"\n' +
    'bright_yellow = "' + p.bright_yellow + '"\n' +
    'bright_green = "' + p.bright_green + '"\n' +
    'bright_cyan = "' + p.bright_cyan + '"\n' +
    'bright_blue = "' + p.bright_blue + '"\n' +
    'bright_magenta = "' + p.bright_magenta + '"\n'
}
