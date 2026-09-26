// Naming and sizing a shared map.
//
// Everything here answers a question asked before any bytes move: what the
// exported file is called, which frames the loop is made of, and what the
// picture says about where it came from. The reasons are the ones that bite
// later rather than now.
//
// The name is a path component, and it is built out of a CAMS layer title —
// which arrives in a WMS capabilities document fetched from a remote host. So
// the name is not text to be tidied, it is a path segment to be constrained:
// `slug` leaves only `[a-z0-9-]` and cannot produce an empty one, `.`, `..` or
// anything with a separator in it. That is also why the share notification can
// name the file without stripping it — the sink is safe by construction rather
// than by a second pass over an already-built string.
//
// The credit line moved here because sharing makes it load-bearing. On screen
// the attribution is a caption in the corner; a shared air-quality image is a
// picture of ECMWF's data with nothing on it naming ECMWF, which is the one
// thing the licence and DESIGN.md's attribution rule both ask for.

.pragma library

.import "CamsModel.js" as CamsModel

// A GIF is frames, and every frame costs encode time in a plain-Python encoder.
// Eight is the window that still reads as motion at the delay below — enough
// to see where the rain went, few enough that the export finishes while the
// person is still looking at the button.
var MAX_GIF_FRAMES = 8

// RainViewer publishes ten minutes apart, so real time is not an option. A
// third of a second per frame over eight frames is a two-and-a-half second
// loop, which is the speed people read a loop at anyway.
var FRAME_DELAY_CS = 30

// Long enough to name a species and its units, short enough that the file name
// is not a sentence. The counter and the stamp add twelve more characters.
var SLUG_MAX = 40

// The credit line the map draws in its own corner, per view. Radar is
// RainViewer over Natural Earth; every CAMS category is Copernicus CAMS over
// Natural Earth. Open-Meteo is in the README's data sources rather than here
// because it supplies the forecast behind the storm alert, not the picture.
var ATTRIBUTION = {
  "radar": "RainViewer · Natural Earth",
  "default": "Copernicus CAMS/ECMWF · Natural Earth"
}

function attribution(category) {
  return ATTRIBUTION[String(category || "")] || ATTRIBUTION["default"]
}

// Letters that are not ASCII and do not decompose into it. The Greek mu is the
// one that matters: CAMS publishes its concentrations in µg/m³, and NFKD
// normalises the micro sign to the Greek small letter mu rather than to a
// "u" with a mark, so a purely decompose-and-strip pass turns "µg/m³" into
// "g-m3" and drops the unit's own letter. Anything else in a layer title is
// decoration, and decoration is what the dash is for.
var TRANSLITERATE = /[\u03BC\u00B5]/g

// A filesystem-safe stem for anything. Lowercase, letters and digits only, one
// word per dash, capped, and never empty: a title that reduces to nothing
// becomes "map" rather than a name the helper has to reject.
function slug(text) {
  var cleaned = String(text === null || text === undefined ? "" : text)
    .normalize("NFKD")
    // The decomposition above splits an accented letter from its mark, so
    // dropping the marks leaves the base letter behind: "époussières" becomes
    // "epoussieres" rather than being deleted whole.
    .replace(/[\u0300-\u036f]/g, "")
    .replace(TRANSLITERATE, "u")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
  if (cleaned.length > SLUG_MAX) cleaned = cleaned.slice(0, SLUG_MAX).replace(/-+$/g, "")
  return cleaned.length > 0 ? cleaned : "map"
}

// The file name, without its extension: `akash-<what>-<when>`. The extension
// is the helper's to choose, because the mode is what picks it, and a name that
// disagreed with the bytes in it is worse than no name.
//
// Built by hand rather than with toISOString, which is UTC: a share taken at
// 23:40 in Auckland must not be stamped 11:40 on the same day.
function stamp(when) {
  var date = when ? new Date(when) : new Date()
  if (isNaN(date.getTime())) date = new Date()
  function two(value) { return (value < 10 ? "0" : "") + value }
  return String(date.getFullYear())
    + two(date.getMonth() + 1)
    + two(date.getDate())
    + "-" + two(date.getHours())
    + two(date.getMinutes())
}

function fileName(kind, when) {
  return "akash-" + slug(kind) + "-" + stamp(when)
}

// The frames the loop is made of: the newest `count`, or all of them when
// there are fewer. The window is at the end, not the start — an animated share
// wants to arrive at the frame the map was already showing, not to open two
// hours ago.
function frameIndexes(available, count) {
  var total = Math.max(0, Math.floor(Number(available) || 0))
  if (total === 0) return []
  var take = Math.min(MAX_GIF_FRAMES, Math.max(1, Math.floor(Number(count) || 0)), total)
  var first = total - take
  var indexes = []
  for (var i = first; i < total; i++) indexes.push(i)
  return indexes
}

// Which frames a share is made of.
//
// A loop is the newest MAX_GIF_FRAMES: an animated share wants to arrive at the
// frame the map was already showing, not to open two hours ago.
//
// A still is the frame the user is looking at, and that is a different question.
// Somebody who has scrubbed back to the middle of a storm and hits share means
// that frame — so the still is the current index, clamped into the list, and
// not the newest one. Sharing the newest frame because it was easier to name
// would answer a question nobody asked.
function windowFor(mode, available, current) {
  var total = Math.max(0, Math.floor(Number(available) || 0))
  if (total === 0) return []
  if (mode === "gif") return frameIndexes(total, MAX_GIF_FRAMES)

  var index = Math.floor(Number(current))
  if (!isFinite(index) || index < 0) index = 0
  return [Math.min(index, total - 1)]
}

// A sentence for a notification body.
//
// The body of a toast is rendered by the shell with `AutoText`, which decides
// per string whether it is markup — so a string carrying `<` reaches the
// process that owns the bar, the panels and the lock screen as markup rather
// than as a caption. Three characters are removed for that reason and the
// length is capped; nothing else is, because what goes in here is a sentence
// this plugin wrote about the user's own files, and stripping the rest of it
// would be a filter standing in for judgement rather than one.
//
// The control characters and the bidi overrides go because a helper's message
// comes from `strerror` and from a name, and neither should be able to reorder
// what the user reads.
var CONTROL = /[\u0000-\u001F\u007F-\u009F\u200E\u200F\u202A-\u202E\u2066-\u2069]/g

function plain(text) {
  return String(text === null || text === undefined ? "" : text)
    // The whitespace that is also a control character, turned into a space
    // first. Taking the control range first would turn "first line\nsecond
    // line" into "first linesecond line" — two words glued together, which
    // reads as a different message rather than as a broken one.
    .replace(/[\r\n\t\v\f]+/g, " ")
    .replace(CONTROL, "")
    .replace(/[<>&]/g, "")
    // And collapse again, because removing a `&` from "a & b" leaves the two
    // spaces that surrounded it touching.
    .replace(/\s+/g, " ")
    .trim()
}

// What the exported picture is called after. Radar is the radar; a CAMS layer
// is named by its own title, so a shared overlay says which one it is. The
// title is remote text, so it goes through `slug` on the way into the name.
function kindFor(category, layer, layerTitle) {
  if (String(category || "") === "radar") return "radar"
  var label = layerTitle || CamsModel.layerLabel(layer)
  return slug(label || "air-quality")
}
