const { test } = require("node:test")
const assert = require("node:assert")
const { loadLibrary, TileMath } = require("./load.js")

const CamsModel = require("./load.js").loadLibrary("CamsModel.js", { TileMath })
const Share = loadLibrary("Share.js", { CamsModel })

// The name of an exported file is a path component built out of a CAMS layer
// title, which arrives in a capabilities document fetched from a remote host.
// So these are not tests about tidy strings: they are the tests that stand
// between a remote document and a pathname, and between that pathname and a
// notification body the plugin cannot render as plain text.

// ---------------------------------------------------------------- the slug

test("a layer title becomes something a filesystem will take", () => {
  assert.strictEqual(Share.slug("PM2.5"), "pm2-5")
  assert.strictEqual(Share.slug("AOD 550nm"), "aod-550nm")
  assert.strictEqual(Share.slug("Ozone Total Column"), "ozone-total-column")
})

test("accents are folded rather than deleted whole", () => {
  // NFKD splits the mark off the letter. Dropping only the marks leaves the
  // letter, so "µg/m³" reduces to "ug" and "m" instead of vanishing.
  assert.strictEqual(Share.slug("Fine particles (µg/m³)"), "fine-particles-ug-m3")
  assert.strictEqual(Share.slug("époussières"), "epoussieres")
})

test("the slug can only ever be a path component", () => {
  // The one property that matters. Everything else here is a preference.
  const nasty = [
    "../../etc/passwd", "..", ".", "/etc/passwd", "a/b", "a\\b",
    "./relative", "~", "-dash", "--flag", "a b", "a\tb", "a\nb", "\u0000",
    "C:\\Windows", "a;b", "a$b", "a`b", "*", "?", "\u0000"
  ]
  for (const value of nasty) {
    const slug = Share.slug(value)
    assert.match(slug, /^[a-z0-9-]*$/, `slug(${JSON.stringify(value)}) = ${JSON.stringify(slug)}`)
    assert.ok(slug.length > 0, `slug(${JSON.stringify(value)}) is empty`)
    assert.notStrictEqual(slug, ".")
    assert.notStrictEqual(slug, "..")
    assert.ok(!slug.startsWith("-"), `slug(${JSON.stringify(value)}) starts with a dash`)
  }
})

test("a title with nothing usable in it still names the file something", () => {
  // An empty stem would be a name the helper has to reject, and a rejected
  // share is worse than one called "map".
  for (const value of ["", "   ", "…", "!!!", "---", "°", "→"]) {
    assert.strictEqual(Share.slug(value), "map", JSON.stringify(value))
  }
})

test("the slug is capped, and never ends on a dash it cut", () => {
  const long = Share.slug("a".repeat(200))
  assert.ok(long.length <= Share.SLUG_MAX, `length ${long.length}`)
  assert.ok(!long.endsWith("-"))
  // And a name that is one dash run followed by letters is not truncated into
  // a bare dash.
  const trimmed = Share.slug("b".repeat(Share.SLUG_MAX - 2) + " tail")
  assert.ok(!trimmed.endsWith("-"), trimmed)
  assert.ok(trimmed.length <= Share.SLUG_MAX)
})

// ------------------------------------------------------------- the file name

test("the name carries what it is and when it was taken", () => {
  // Built by hand rather than by toISOString, which is UTC: a share taken at
  // 23:40 in Auckland is not taken at 11:40 on the same day.
  const name = Share.fileName("radar", new Date(2026, 8, 26, 14, 30))
  assert.strictEqual(name, "akash-radar-20260926-1430")
})

test("the name is decided once, so a loop lands in one file", () => {
  // Not a property of this function so much as of its caller, but it is the
  // reason fileName takes a date rather than a clock: called per frame it
  // would produce eight files a minute apart.
  const a = Share.fileName("radar", new Date(2026, 8, 26, 14, 30, 0))
  const b = Share.fileName("radar", new Date(2026, 8, 26, 14, 30, 59))
  assert.strictEqual(a, b)
})

test("a single-digit month, day, hour or minute is still two digits", () => {
  // Otherwise "2026-1-2-3-4" sorts nowhere near "2026-01-02-03-04".
  assert.strictEqual(Share.fileName("radar", new Date(2026, 0, 2, 3, 4)), "akash-radar-20260102-0304")
})

test("a missing or impossible date falls back to now rather than NaN", () => {
  for (const when of [undefined, null, new Date("nonsense"), 0]) {
    const name = Share.fileName("radar", when)
    assert.match(name, /^akash-radar-\d{8}-\d{4}$/, `${JSON.stringify(when)} -> ${name}`)
  }
})

test("the kind is chosen from what the map is drawing", () => {
  assert.strictEqual(Share.kindFor("radar", null, ""), "radar")
  assert.strictEqual(Share.kindFor("air-quality", { title: "PM2.5" }, ""), "pm2-5")
  assert.strictEqual(Share.kindFor("allergens", { short: "Grass" }, ""), "grass")
  // A layer with neither a title nor a short name is still named something.
  assert.strictEqual(Share.kindFor("aerosols", null, ""), "air-quality")
  // And a title passed in beats the layer object, which is how the panel keeps
  // the name stable against a capabilities refresh mid-share.
  assert.strictEqual(Share.kindFor("air-quality", { title: "PM2.5" }, "PM10"), "pm10")
})

test("the whole name is safe whatever the title was", () => {
  // The end-to-end version of the two properties above: what comes out of
  // fileName is what reaches a path and then a notification body.
  for (const title of ["../../etc/passwd", "PM2.5", "…", "AOD 550nm & <b>tags</b>", ""]) {
    const name = Share.fileName(Share.kindFor("air-quality", { title }, ""), new Date(2026, 8, 26))
    assert.match(name, /^[a-z0-9][a-z0-9-]{0,63}$/, name)
  }
})

// -------------------------------------------------------------- the frame window

test("a loop takes the newest frames, not the oldest", () => {
  // An animated share wants to arrive at the frame the map was already
  // showing, not to open two hours ago.
  assert.deepStrictEqual(Share.frameIndexes(12, 8), [4, 5, 6, 7, 8, 9, 10, 11])
})

test("a loop is never longer than the frames there are", () => {
  assert.deepStrictEqual(Share.frameIndexes(3, 8), [0, 1, 2])
  assert.deepStrictEqual(Share.frameIndexes(1, 8), [0])
  assert.deepStrictEqual(Share.frameIndexes(8, 8), [0, 1, 2, 3, 4, 5, 6, 7])
})

test("a loop is never longer than the ceiling", () => {
  // The encoder is a plain-Python one and every frame costs it real time, so
  // the count is bounded in the library and not only in the panel's arithmetic.
  const indexes = Share.frameIndexes(100, 100)
  assert.strictEqual(indexes.length, Share.MAX_GIF_FRAMES)
  assert.strictEqual(Share.MAX_GIF_FRAMES, 8)
})

test("the window is contiguous, in range, and ending at the newest frame", () => {
  for (const available of [0, 1, 2, 5, 8, 9, 31]) {
    for (const wanted of [1, 2, 8, 20]) {
      const indexes = Share.frameIndexes(available, wanted)
      const take = Math.min(Share.MAX_GIF_FRAMES, wanted, available)
      assert.strictEqual(indexes.length, take, `${available}/${wanted}`)
      if (take === 0) continue
      assert.deepStrictEqual(indexes, Array.from({ length: take }, (_, i) => available - take + i))
      assert.ok(Math.max(...indexes) < available)
    }
  }
})

test("a frame count that is not a number is one, not NaN", () => {
  // The panel asks for a constant, so this cannot happen today; the property
  // worth keeping is that it cannot produce a window full of NaN either.
  for (const wanted of [undefined, null, "nonsense", NaN, -3, 0]) {
    const indexes = Share.frameIndexes(4, wanted)
    assert.ok(indexes.every(Number.isInteger), `${wanted} -> ${JSON.stringify(indexes)}`)
  }
})

test("no frames means no window at all", () => {
  assert.deepStrictEqual(Share.frameIndexes(0, 8), [])
  assert.deepStrictEqual(Share.frameIndexes(-4, 8), [])
  assert.deepStrictEqual(Share.frameIndexes(undefined, 8), [])
})

// ------------------------------------------------------------ which frames

test("a still is the frame on screen, not the newest one", () => {
  // Somebody who has scrubbed back to the middle of a storm and hits share
  // means that frame. Sharing the newest one because it was easier to name
  // answers a question nobody asked.
  assert.deepStrictEqual(Share.windowFor("image", 12, 3), [3])
  assert.deepStrictEqual(Share.windowFor("image", 12, 0), [0])
  assert.deepStrictEqual(Share.windowFor("image", 12, 11), [11])
})

test("a still asked for a frame that is not there takes the newest one", () => {
  // A frame list replaced between the panel reading its index and the share
  // starting. Clamping to the newest frame is the answer; indexing past the
  // end is an undefined frame written to a path.
  assert.deepStrictEqual(Share.windowFor("image", 4, 9), [3])
  assert.deepStrictEqual(Share.windowFor("image", 1, 5), [0])
})

test("a still with nothing sensible to point at takes the first frame", () => {
  for (const current of [-1, undefined, null, NaN, "nonsense"]) {
    assert.deepStrictEqual(Share.windowFor("image", 5, current), [0],
      `${current} -> ${JSON.stringify(Share.windowFor("image", 5, current))}`)
  }
})

test("a fractional frame index is floored, not refused", () => {
  // A slider position is not an integer, and the frame it is on is the one
  // below it. Refusing would mean a share that fails whenever the scrubber
  // lands between two frames, which is most of the time.
  assert.deepStrictEqual(Share.windowFor("image", 5, 1.7), [1])
  assert.deepStrictEqual(Share.windowFor("image", 5, "3"), [3])
  assert.deepStrictEqual(Share.windowFor("image", 5, 3.999), [3])
})

test("a still is always exactly one frame, and a loop is never fewer than one", () => {
  for (const available of [1, 2, 8, 40]) {
    for (const current of [0, 2, 7, 39]) {
      const still = Share.windowFor("image", available, current)
      assert.strictEqual(still.length, 1, `${available}/${current}`)
      assert.ok(still[0] >= 0 && still[0] < available)
      const loop = Share.windowFor("gif", available, current)
      assert.ok(loop.length >= 1 && loop.length <= Share.MAX_GIF_FRAMES)
      assert.ok(Math.max(...loop) < available)
    }
  }
})

test("a loop ignores the frame on screen and takes the newest ones", () => {
  // Deliberately different from a still: the loop is the storm's last while,
  // and scrubbing to a frame and asking for a loop is asking for the loop.
  assert.deepStrictEqual(Share.windowFor("gif", 12, 0), [4, 5, 6, 7, 8, 9, 10, 11])
  assert.deepStrictEqual(Share.windowFor("gif", 12, 11), [4, 5, 6, 7, 8, 9, 10, 11])
})

test("a share of no frames is no frames", () => {
  for (const mode of ["image", "gif"]) {
    assert.deepStrictEqual(Share.windowFor(mode, 0, 0), [], mode)
    assert.deepStrictEqual(Share.windowFor(mode, -1, 0), [], mode)
    assert.deepStrictEqual(Share.windowFor(mode, undefined, undefined), [], mode)
  }
})

test("any mode other than a loop is a still", () => {
  // The panel only ever asks for "image" or "gif", but a third value reaching
  // here should be the safe answer rather than an empty window.
  assert.deepStrictEqual(Share.windowFor("apng", 9, 4), [4])
  assert.deepStrictEqual(Share.windowFor("", 9, 4), [4])
})

// ------------------------------------------------- the notification body's text

test("a helper sentence reaches a toast as a caption, not as markup", () => {
  // The body of a notification is rendered by the shell with `AutoText`, which
  // decides per string whether it is markup. A string carrying `<` therefore
  // reaches the process that owns the bar, the panels and the lock screen as
  // markup rather than as words. The helper's own messages are about the user's
  // files, so there is no third party in them — but the sink cannot render as
  // plain text and the three characters that start markup have to go.
  assert.strictEqual(Share.plain("refused <img src=x onerror=alert(1)>"), "refused img src=x onerror=alert(1)")
  assert.strictEqual(Share.plain("a & b"), "a b")
  assert.strictEqual(Share.plain("a > b"), "a b")
  assert.strictEqual(Share.plain("a < b"), "a b")
})

test("nothing that could reorder or hide survives a helper sentence", () => {
  // `strerror` and a path both reach this, and a bidi override in the middle of
  // a sentence is enough to make it say something other than what it says.
  // Written as escapes rather than as the characters, for the same reason the
  // library's own pattern is: a literal control byte in a source file makes the
  // file binary to half the tools that read it, and the plugin's scanner
  // refuses a source file that has one.
  const nasty = [
    ["a\u0000b", "ab"],                 // NUL
    ["a\u0007b", "ab"],                 // BEL
    ["a\u001Fb", "ab"],                 // another C0 control
    ["a\u007Fb", "ab"],                 // DEL
    ["a\u0085b", "ab"],                 // C1
    ["a\u202Eb\u202Cc", "abc"],        // bidi override
    ["a\u2066b\u2069c", "abc"],        // bidi isolate
    ["a\u200Eb\u200Fc", "abc"]         // LRM / RLM
  ]
  for (const [value, wanted] of nasty) {
    assert.strictEqual(Share.plain(value), wanted,
      JSON.stringify(value) + " -> " + JSON.stringify(Share.plain(value)))
  }
})

test("a helper sentence is one line", () => {
  // The panel takes the first line, so a helper that printed a stack would
  // otherwise have its first line shown and the rest silently dropped — or,
  // worse, shown as a second paragraph of a toast.
  assert.strictEqual(Share.plain("first line\nsecond line"), "first line second line")
  assert.strictEqual(Share.plain("  spaced   out  "), "spaced out")
})

test("no helper sentence is never an exception", () => {
  // The panel asks for this on every exit from a share, including the ones
  // where the helper worked perfectly and said nothing.
  for (const value of ["", null, undefined, 0, false, NaN, {}]) {
    assert.strictEqual(typeof Share.plain(value), "string", JSON.stringify(value))
  }
})

// ------------------------------------------------------------- the credit line

test("each view is credited to whoever drew it", () => {
  // Sharing makes this load-bearing. On screen the line is a caption in the
  // corner; a shared air-quality image is a picture of ECMWF's data, and an
  // image that does not say so is unattributed however the plugin behaves.
  assert.strictEqual(Share.attribution("radar"), "RainViewer · Natural Earth")
  for (const category of ["air-quality", "allergens", "aerosols", "uv"]) {
    assert.strictEqual(Share.attribution(category), "Copernicus CAMS/ECMWF · Natural Earth")
  }
})

test("a view nobody has heard of is still credited", () => {
  // A wrong credit is worse than a generic one, so anything that is not radar
  // gets the air-quality line rather than the radar's.
  for (const category of ["", undefined, "something-new"]) {
    assert.strictEqual(Share.attribution(category), "Copernicus CAMS/ECMWF · Natural Earth")
  }
})

test("both credit lines name the ground the map is drawn on", () => {
  for (const category of ["radar", "air-quality"]) {
    assert.match(Share.attribution(category), /Natural Earth/, category)
  }
})
