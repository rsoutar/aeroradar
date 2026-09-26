const { test } = require("node:test")
const assert = require("node:assert")
const { readFileSync, readdirSync } = require("node:fs")
const { join } = require("node:path")
const { RadarModel } = require("./load.js")

// Every stream that reaches the shell process, pinned by name.
//
// The plugin does not run beside the desktop, it runs inside it: one process
// owns the bar, the panels, the lock screen and the polkit dialog. Anything
// collected whole into it is collected into all of that, so each stream needs
// a ceiling — and the ceilings that get forgotten are the ones nobody has
// written down. This list is the inventory, and the tests below hold the
// sources to it, so a stream added later fails here rather than turning up in
// a review.
//
// Where the ceilings live differs by path. The Open-Meteo and RainViewer
// requests are curl, and their ceilings sit in the RadarModel command
// builders, checked here against the numbers measured off the endpoints. The
// CAMS paths go through cams.py, which caps its own reads while streaming —
// pinned in test/cams.test.py and inventoried here as a document.

const ROOT = join(__dirname, "..")
const QML = ["BarWidget.qml", "BoundedProcess.qml", "Panel.qml", "Service.qml"]
  .concat(readdirSync(join(ROOT, "ui")).filter(name => name.endsWith(".qml")).map(name => "ui/" + name))

const source = Object.fromEntries(QML.map(name => [name, readFileSync(join(ROOT, name), "utf8")]))
const everything = Object.values(source).join("\n")

// `bounded` means it runs through BoundedProcess, which owns the answered
// flag and the one collector. `collects` marks the ones whose stdout is read
// back into this process at all — notifyProc hands a message to
// omarchy-notification-send and reads nothing back.
const PROCESSES = [
  { id: "manifestProc", file: "Service.qml", bounded: true, collects: true, builder: "manifestCommand" },
  { id: "camsInitProc", file: "Service.qml", bounded: true, collects: true, builder: null },
  { id: "aqProc", file: "Service.qml", bounded: true, collects: true, builder: null },
  { id: "forecastProc", file: "Service.qml", bounded: true, collects: true, builder: "forecastCommand" },
  { id: "notifyProc", file: "Service.qml", bounded: false, collects: false, builder: null },
  { id: "geocodeProc", file: "Panel.qml", bounded: true, collects: true, builder: "geocodingCommand" },
  { id: "locationSaveProc", file: "Panel.qml", bounded: true, collects: false, builder: null },
  { id: "tileFetch", file: "ui/TileLayer.qml", bounded: false, collects: true, builder: null },
  // The share helper. It reads a few kilobytes of answers — a run directory
  // name and a published path — and never anything else: the frames go to disk
  // from Qt's own saveToFile and are read back inside the helper, so no image
  // bytes are ever collected into this process. clipboardProc hands a file to
  // wl-copy and reads nothing at all.
  { id: "shareProc", file: "Panel.qml", bounded: true, collects: true, builder: null },
  { id: "clipboardProc", file: "Panel.qml", bounded: true, collects: false, builder: null },
]

// Files read straight into the process, and why each one carries no ceiling
// of its own. locationFile is Omarchy's own state file, basemapFile is a
// vendored asset, and basemapCacheFile is the decoded form of that asset,
// written by the plugin itself and read only if it still carries the format
// the code expects. The two CAMS files are this plugin's own directory,
// written by cams.py out of responses it capped while streaming, and
// distilled — the caps.json holds one small record per layer, never the
// document it came from.
const FILE_READS = [
  { id: "locationFile", file: "Service.qml" },
  { id: "basemapFile", file: "Service.qml" },
  { id: "basemapCacheFile", file: "Service.qml" },
  { id: "camsCapsFile", file: "Service.qml" },
  { id: "camsStateFile", file: "Service.qml" },
]

function idsOf(pattern) {
  const found = []
  for (const [file, text] of Object.entries(source)) {
    for (const match of text.matchAll(pattern)) found.push({ id: match[1], file })
  }
  return found
}

// ------------------------------------------------------------------ inventory

test("the processes in the sources are the ones written down here", () => {
  // BoundedProcess.qml holds the component definition, not an instance.
  const found = idsOf(/(?:(?:Bounded)?Process) \{\s*\n\s*id: (\w+)/g)
    .filter(p => p.file !== "BoundedProcess.qml")
  assert.deepStrictEqual(
    found.map(p => `${p.file}:${p.id}`).sort(),
    PROCESSES.map(p => `${p.file}:${p.id}`).sort())
})

test("the file reads in the sources are the ones written down here", () => {
  const found = idsOf(/FileView \{\s*\n\s*id: (\w+)/g)
  assert.deepStrictEqual(
    found.map(f => `${f.file}:${f.id}`).sort(),
    FILE_READS.map(f => `${f.file}:${f.id}`).sort())
})

test("every stdout collector is explicitly inventoried", () => {
  // TileLayer collects a bounded, base64-encoded PNG because Qt's HTTPS
  // loader can stall after a shell restart. Other collectors live in
  // BoundedProcess, and new ones need an entry in PROCESSES above.
  const found = []
  for (const [file, text] of Object.entries(source)) {
    for (const match of text.matchAll(/StdioCollector/g)) found.push(file)
  }
  assert.deepStrictEqual(found.sort(), ["BoundedProcess.qml", "Panel.qml", "ui/TileLayer.qml"])
})

test("every stderr collector is explicitly inventoried too", () => {
  // A helper's reason for refusing is a stream into this process just as much
  // as its answer is, and it is the one that gets forgotten: stderr is where
  // a program explains itself, and a plugin that collects stdout and drops
  // stderr on the floor cannot report anything except "it did not work". The
  // panel collects the share helper's so the reason can reach the toast.
  const found = []
  for (const [file, text] of Object.entries(source)) {
    if (/\bstderr\s*:/.test(text)) found.push(file)
  }
  assert.deepStrictEqual(found.sort(), ["Panel.qml"], "an unlisted process claims stderr")
})

// The share process's own answer handler. Anchored past the stderr collector
// so it cannot match one of the several other `onResponded: function(exitCode,
// text)` handlers in this file — some of which are written on a single line and
// would swallow everything up to the next four-space brace.
function shareAnswerHandler(panel) {
  const anchor = panel.indexOf("stderr: StdioCollector")
  assert.ok(anchor > 0, "the share helper's stderr is not collected")
  const handler = /onResponded: function\(exitCode, text\) \{[\s\S]*?\n {4}\}/.exec(panel.slice(anchor))
  assert.ok(handler, "the share process answers nothing")
  return handler[0]
}

test("a claimed stderr is not left to decide anything on its own", () => {
  // `onStreamFinished` fires before the exit code exists, so a collector that
  // interprets what it collected there would read a transfer cut short by a
  // ceiling as one that completed. The share helper's stderr is read in
  // onResponded for exactly that reason.
  const panel = source["Panel.qml"]
  const collector = /stderr: StdioCollector \{[\s\S]*?\n {4}\}/.exec(panel)
  assert.ok(collector, "the share helper's stderr is not collected after all")
  assert.ok(!/onStreamFinished/.test(collector[0]), "the stderr collector decides something")
  const handler = shareAnswerHandler(panel)
  assert.match(handler, /shareErrors\.text/, "the collected stderr is never read")
  assert.match(handler, /applyShareResponse\(exitCode, text\)/,
    "the answer is never handled")
})

test("the collected stderr is read, never assigned", () => {
  // This one is invisible to qmllint, which passes a plugin that assigns to
  // `StdioCollector.text`. That property is `isReadonly: true` — a getter over
  // the collector's own buffer — so the assignment throws, and a throw inside
  // `onResponded` abandons the rest of the handler.
  //
  // The symptom is the worst kind: `share.py begin` has already created the run
  // directory, the panel never learns its name, the progress row sits there
  // until the user cancels, and the cancel cannot clean up after it either
  // because it never knew there was anything to clean up. Two empty
  // directories under the plugin's own config, and a share button that looks
  // broken.
  const panel = source["Panel.qml"]
  const handler = shareAnswerHandler(panel)
  assert.ok(!/shareErrors\.\w+\s*=[^=]/.test(handler),
    "the stderr collector's read-only property is assigned to")
  // And nothing anywhere in the file may write to a collector's text — the same
  // property on the stdout BoundedProcess already collects.
  assert.ok(!/\b(out|shareErrors)\.text\s*=[^=]/.test(panel),
    "something assigns to a collector's read-only text property")
})

test("a share outside the radar grabs at once rather than staging a frame", () => {
  // setTimelineIndex() refuses any view that is not the radar, so an
  // air-quality share that staged a frame would wait for a swap that is never
  // going to happen and fall through to the eight-second fence. Every air
  // quality share would feel like it had hung.
  const text = bodyOf(source["Panel.qml"], "function captureNextFrame")
  const branch = text.indexOf("if (!root.radarMode)")
  const stage = text.indexOf("setTimelineIndex(index)")
  assert.ok(branch > 0, "captureNextFrame does not branch on the view")
  assert.ok(stage > branch, "the radar-only staging happens before the non-radar branch")
  assert.match(text.slice(branch, stage), /grabFrame\(\)/,
    "the non-radar branch does not grab the frame it is already showing")
})

test("a frame that is already on screen is not staged again", () => {
  // `setTimelineIndex` assigns `frameIndex = index`, which fires no signal when
  // the value is unchanged — so `showFrame` never runs, the swap is never
  // pending, `finishSwap` never releases a grab, and the only thing left is the
  // eight-second fence.
  //
  // A still is *always* this case, because a still is the frame the user is
  // looking at. So without this branch every still waited out the fence: eight
  // seconds of a map that is not moving, under a progress row saying it is
  // rendering.
  const text = bodyOf(source["Panel.qml"], "function captureNextFrame")
  const already = text.indexOf("if (index === frameIndex)")
  const stage = text.indexOf("setTimelineIndex(index)")
  assert.ok(already > 0, "captureNextFrame does not consider a frame that is already showing")
  assert.ok(already < stage, "the already-showing case is not handled before staging")
  const between = text.slice(already, stage)
  assert.match(between, /shareSettle\.restart\(\)/,
    "the already-showing case neither stages nor settles, so no grab is ever released")
  assert.ok(!/shareFence\.restart\(\)/.test(between),
    "the already-showing case falls through to the fence, so a still takes eight seconds")
})

test("the settle timer has one name for both the things that use it", () => {
  // It is both "the crossfade finished" and "the frame was already there".
  // Two names for one timer is how a rename leaves one call site behind
  // stopping a timer that no longer exists.
  const panel = source["Panel.qml"]
  assert.ok(!/shareFade/.test(panel), "the old timer name is still in the file")
  assert.match(panel, /id: shareSettle[\s\S]{0,120}interval: root\.shareSettleMs/,
    "the settle timer is not bound to the settle interval")
  assert.match(panel, /readonly property int shareSettleMs: \d+/,
    "the settle interval is not a stated number")
})

test("the processes written down as bounded really are", () => {
  for (const process of PROCESSES.filter(p => p.bounded)) {
    const re = new RegExp(`BoundedProcess \\{\\s*\\n\\s*id: ${process.id}\\b`)
    assert.match(source[process.file], re, `${process.id} is not bounded`)
  }
})

// ------------------------------------------------------------------ ceilings

test("every request carries a ceiling on bytes as well as on time", () => {
  // `--max-time` bounds how long a transfer may run, not how much it may
  // deliver: a host that answers fast enough can send as much as the link
  // carries for the whole window.
  for (const name of ["manifestCommand", "geocodingCommand", "forecastCommand"]) {
    const command = name === "manifestCommand" ? RadarModel.manifestCommand()
      : name === "geocodingCommand" ? RadarModel.geocodingCommand("x", 5)
      : RadarModel.forecastCommand([{ latitude: 0, longitude: 0 }], 4, 2)

    assert.strictEqual(command[0], "curl", name)
    assert.ok(command.includes("--max-time"), `${name} has no time limit`)
    assert.ok(command.includes("--max-filesize"), `${name} has no size limit`)
    assert.ok(command.includes("-fsS"), `${name} would parse an error page as data`)

    const bytes = Number(command[command.indexOf("--max-filesize") + 1])
    const seconds = Number(command[command.indexOf("--max-time") + 1])
    assert.ok(bytes > 0 && bytes <= 1024 * 1024, `${name} caps at ${bytes} bytes`)
    assert.ok(seconds > 0 && seconds <= 30, `${name} waits up to ${seconds}s`)
  }
})

test("the ceilings leave room above what the endpoints actually return", () => {
  // Measured against the real endpoints, as upstream measured them: the
  // RainViewer manifest is 766 bytes, a five-result geocoding answer 1,834,
  // and a five-point forecast at the widest window this plugin asks for
  // 9,269. A ceiling under what the service really sends is an outage nobody
  // would think to look for.
  assert.ok(RadarModel.MANIFEST_MAX_BYTES >= 766 * 10)
  assert.ok(RadarModel.GEOCODING_MAX_BYTES >= 1834 * 10)
  assert.ok(RadarModel.FORECAST_MAX_BYTES >= 9269 * 10)
})

test("the CAMS helper is the one place the network is read without curl", () => {
  // The CAMS paths run through cams.py instead, and its ceilings are pinned
  // where its logic lives: one urlopen in the whole file, behind the
  // per-chunk budget of fetch_bytes, whose numbers are asserted in
  // test/cams.test.py against what the endpoints actually return.
  const camsPy = readFileSync(join(ROOT, "cams.py"), "utf8")
  assert.strictEqual((camsPy.match(/urlopen\(/g) || []).length, 1,
    "a second network read in cams.py is a stream that skipped its ceiling")
  assert.match(camsPy, /def fetch_bytes\(/, "the capped read path is missing")
  assert.match(camsPy, /max_bytes/, "fetch_bytes takes no budget")
  assert.match(camsPy, /CAPABILITIES_MAX_BYTES/)
  assert.match(camsPy, /PROBE_MAX_BYTES/)
})

test("no request is built outside the places that put the ceilings on", () => {
  // TileLayer is the sole QML exception: Qt's image TLS transport can stall
  // after a restart, so it uses a bounded curl pipe and decodes a local data
  // URL. All other QML requests must still come from their builders.
  const withoutTiles = Object.entries(source)
    .filter(([file]) => file !== "ui/TileLayer.qml")
    .map(([, text]) => text).join("\n")
  assert.ok(!/"curl"/.test(withoutTiles),
    "QML builds a curl command outside the bounded tile transport")
  const tiles = source["ui/TileLayer.qml"]
  assert.match(tiles, /curl -fsS --max-time 10 --max-filesize 1048576/)
  assert.match(tiles, /base64 --wrap=0/)
})

// ------------------------------------------------------------------ answering

test("a fork that never ran is answered once, in BoundedProcess", () => {
  // A process that cannot be started emits neither `started` nor `exited` and
  // goes from running to not running in silence. BoundedProcess answers that
  // case centrally — with a flag reset on every launch, so a previous run's
  // answer can never mask the next one.
  const block = source["BoundedProcess.qml"]
  assert.match(block, /property bool answered: false/)
  assert.match(block, /function launch\([\s\S]{0,120}answered = false/)
  assert.match(block, /onRunningChanged[\s\S]{0,240}answered/,
    "BoundedProcess does not answer a fork that never ran")
})

test("no decision is taken in a collector, where the exit code does not exist yet", () => {
  // `onStreamFinished` fires before `onExited`, so a transfer cut short by a
  // ceiling would be read there as one that completed.
  assert.ok(!/onStreamFinished\s*:/.test(everything), "a collector is deciding something")
})

test("a flag that gates everything is cleared before the answer can return", () => {
  // `checking` and `aqChecking` gate the next check and what the UI shows
  // while waiting, so if either is left set the plugin does not degrade, it
  // freezes. Clearing them further down, past a guard on the exit code, is
  // the version of this that looks right.
  const start = source["Service.qml"].indexOf("function applyForecastResponse(")
  assert.ok(start > 0, "applyForecastResponse is missing from Service.qml")
  const body = source["Service.qml"].slice(start, start + 900)
  const cleared = body.indexOf("checking = false")
  const returns = body.indexOf("return")
  assert.ok(cleared > 0, "applyForecastResponse never clears checking")
  assert.ok(returns < 0 || cleared < returns,
    "applyForecastResponse can return before clearing checking")

  const aqStart = source["Service.qml"].indexOf("id: aqProc")
  const aqBody = source["Service.qml"].slice(aqStart, aqStart + 2000)
  assert.match(aqBody, /onResponded: function\([^)]*\) \{\s*\n\s*root\.aqChecking = false/,
    "aqProc answers before clearing its in-flight flag")
})

// ------------------------------------------------------------------ images

test("the radar and air tiles are decoded at the size they were asked for", () => {
  // Images are streams too, and their size is decided by whoever serves them.
  assert.match(source["ui/TileLayer.qml"], /sourceSize: Qt\.size\(/, "tiles decode unbounded")
  const air = source["ui/AirLayer.qml"]
  assert.strictEqual((air.match(/sourceSize: Qt\.size\(/g) || []).length, 2,
    "the CAMS overlay decodes unbounded")
})

test("the coverage probe is the one image decode without a ceiling, on purpose", () => {
  // Context2D reads pixels from an image it loaded itself. Handed an Image
  // item — which is what would carry a sourceSize — drawImage produces nothing
  // to read, and every location comes back reported as covered. There is no
  // form of this that both bounds the decode and answers the question.
  //
  // Pinned so that removing the exception means removing this test, rather
  // than the ceiling quietly never having been there.
  assert.match(source["ui/CoverageProbe.qml"], /loadImage\(source\)/)
  // The property assignment, not the word: the comment above it names it.
  assert.ok(!/sourceSize\s*:/.test(source["ui/CoverageProbe.qml"]),
    "if this ever gains a sourceSize, check it still reads pixels before believing it")

  // What bounds it instead.
  assert.strictEqual(RadarModel.isTileHost("https://tilecache.rainviewer.com"), true)
  assert.strictEqual(RadarModel.isTileHost("http://elsewhere"), false)
})

test("the host every tile URL is built from is checked before it is used", () => {
  assert.strictEqual(RadarModel.isTileHost("https://tilecache.rainviewer.com"), true)
  assert.strictEqual(RadarModel.isTileHost("http://tilecache.rainviewer.com"), false)
  assert.strictEqual(RadarModel.isTileHost("anything at all"), false)
})

// ---------------------------------------------------------------- the share

test("the share helper runs as an argv array, with a pinned interpreter", () => {
  // Every argument in the share path is data — a mode, a directory name, a file
  // stem — and the file stem is built from a CAMS layer title that arrived in a
  // WMS capabilities document fetched over the network. A shell string would
  // turn that title into code. So: no shell, an absolute interpreter, -I so no
  // PYTHONPATH rides in, and the helper resolved from the plugin's own
  // directory rather than from a path assembled in QML.
  const panel = source["Panel.qml"]
  assert.match(panel, /readonly property var shareHelper: \["\/usr\/bin\/python3", "-I", "-S", pluginFile\("share\.py"\)\]/,
    "the share helper is not a pinned argv array")
  assert.ok(!/shareProc\.launch\(\s*["'`]/.test(panel), "a share command is a string, not an array")
  assert.ok(!/shareProc\.launch\([^)]*\+ *share[A-Za-z]*\s*\+/.test(panel),
    "a share command is assembled by concatenation")
})

test("the share answer is checked on this side of the process boundary", () => {
  // The helper holds its own stdout to 4 KiB. This is the same bound applied
  // again where the bytes actually land, because the manual's rule is that a
  // cap after the collection is not the cap.
  const panel = source["Panel.qml"]
  assert.match(panel, /shareAnswerMax:\s*4096/, "the share answer has no ceiling here")
  assert.match(panel, /if \(text\.length > root\.shareAnswerMax\)/,
    "the share answer is not measured against its ceiling")

  // And the answer's shape is checked, not assumed. A path that is not a path,
  // a frame count that is not the count asked for, or a byte count that is not
  // a number would each put something unexpected into saveToFile, wl-copy, or
  // a notification body — so each is refused by name.
  assert.match(panel, /lines\.length !== root\.shareTotal \+ 1/,
    "the frame count the helper answered with is not checked against the one asked for")
  assert.match(panel, /answer\.length !== 2/,
    "a published path and its size are not checked for being two fields")
  assert.match(panel, /\(png\|gif\)\$/,
    "a published path is not checked for the extension the mode implies")
  assert.match(panel, /\^\[0-9\]\{1,12\}\$/,
    "a published byte count is not checked for being a number")
})

test("no image bytes are ever collected into the shell process", () => {
  // The frames are several hundred kilobytes each and there are up to eight of
  // them. Qt writes them straight to the paths share.py named, and share.py
  // reads them back through its own descriptors, so the only thing crossing
  // back into this process is a directory name and a published path. A base64
  // or data: URL anywhere in the share path would put a loop's worth of
  // weather into the one process that owns the bar and every panel.
  const panel = source["Panel.qml"]
  assert.ok(!/base64/.test(panel), "the panel base64s something for the share")
  assert.ok(!/data:image/.test(panel), "the panel hands a data: URL to the share path")
  assert.match(panel, /grabToImage\(/, "the frames are not grabbed by Qt")
  assert.match(panel, /saveToFile\(/, "Qt is not the thing writing the frames")
})

// The next three are the shape of the capture loop, and each one was a real bug
// that no other test in the tree could see: the code runs, lints, and only
// misbehaves on a screen.

test("the step between frames is the one that notices there are none left", () => {
  // A timer that grabbed unconditionally would walk off the end of the list and
  // write a file that was never named, and a loop would never be published at
  // all — the share would end in a stall rather than in a file.
  const panel = source["Panel.qml"]
  const timer = /id: shareFrameTimer[\s\S]{0,200}?onTriggered: root\.(\w+)\(\)/.exec(panel)
  assert.ok(timer, "the between-frames timer does not call a share function")
  assert.strictEqual(timer[1], "captureNextFrame",
    `the between-frames timer calls ${timer[1]}() rather than captureNextFrame()`)
  assert.match(panel, /if \(root\.shareCursor >= root\.sharePaths\.length\) \{\s*\n\s*root\.publishShare\(\)/,
    "nothing checks whether the frames have run out before publishing")
})

// A block of QML with its `//` comments taken out. These assertions are about
// the shape of the code, and a comment that *names* the thing being looked for
// is a comment, not a call. `indent` is the column the block's closing brace
// sits at, which is how the block is found without matching its body.
function blockOf(panel, opener, indent) {
  const found = new RegExp(`${opener}[\\s\\S]*?\\n${" ".repeat(indent)}\\}`).exec(panel)
  assert.ok(found, `${opener} is missing from Panel.qml`)
  return found[0].split("\n").map(line => line.replace(/\/\/.*$/, "")).join("\n")
}

function bodyOf(panel, signature) {
  return blockOf(panel, `${signature}\\(\\) \\{`, 2)
}

test("only one grab of the map is ever in flight", () => {
  // grabToImage is queued, not immediate, and two of them on one item each
  // photograph the other's half-finished state. The fence is the third thing
  // that can release a grab, so it has to be stopped by the grab it releases —
  // and the next grab waits for this one's callback, not for a timer.
  const text = bodyOf(source["Panel.qml"], "function grabFrame")
  assert.match(text, /shareFence\.stop\(\)/,
    "grabFrame leaves the fence running, so a second grab can start")
  assert.match(text, /saveToFile\([\s\S]*?shareFrameTimer\.restart\(\)/,
    "the next frame is not started from the grab's own callback")
})

test("the share chooser is declared over the map, not beside it", () => {
  // This is the bug that made the share button look dead.
  //
  // `KeyboardPanel` is a PanelWindow — a separate window, not an item in the
  // panel's own — so a dialog declared at the panel's top level is in a
  // different window from the map and no `z` can raise it above one. It has to
  // be inside that window, and after the key catcher that fills it, or it opens,
  // paints underneath, and eats no clicks.
  const panel = source["Panel.qml"]
  const dialog = panel.indexOf("id: shareChooser")
  const catcher = panel.indexOf("id: keyCatcher")
  assert.ok(dialog > 0, "the share chooser is missing from Panel.qml")
  assert.ok(catcher > 0, "the key catcher is missing from Panel.qml")
  assert.ok(dialog > catcher,
    "the share chooser is declared before the key catcher, so the map paints over it")
  assert.match(panel, /id: shareChooser[\s\S]{0,200}?z: 10/,
    "the share chooser has no z, so its siblings paint over it")
})

test("both of the chooser's options start a share", () => {
  // `ConfirmDialog` reports two buttons and one dismissal gesture through two
  // signals, and they are not the same set:
  //
  //   confirmed()  the right button     — Animated GIF
  //   canceled()   the left button      — PNG image
  //   canceled()   a click on the scrim — neither
  //
  // Wiring `onCanceled` to "close the dialog" is the natural mistake and it is
  // invisible until someone clicks the left one: the dialog closes, the share
  // does not start, and it looks like a broken button. Both options have to
  // reach `startShare`, and only the scrim has to close the dialog.
  const panel = source["Panel.qml"]
  assert.match(panel, /onConfirmed: root\.startShare\("gif"\)/,
    "the right button does not start the animated share")

  const canceled = /onCanceled: \{[\s\S]*?\n {8}\}/.exec(panel)
  assert.ok(canceled, "the chooser's left button is not handled")
  assert.match(canceled[0], /selectedIndex === 0\) root\.startShare\("image"\)/,
    "the left button does not start the image share")
  assert.match(canceled[0], /else root\.shareChooser\.opened = false/,
    "a dismissed chooser does not close")

  // And the two keyboard ways in ask the same question, so they cannot drift
  // from the buttons or from each other.
  const chooser = bodyOf(panel, "function chooseShareFormat")
  assert.match(chooser, /selectedIndex === 0\) root\.startShare\("image"\)/,
    "choosing the image from the keyboard starts nothing")
  assert.match(chooser, /else root\.startShare\("gif"\)/,
    "choosing the loop from the keyboard starts nothing")
  for (const [where, what] of [
    ["onReturnRequested", /onReturnRequested: \{[\s\S]{0,200}?chooseShareFormat\(\)/],
    ["Keys.onPressed", /Keys\.onPressed: function\(event\) \{[\s\S]{0,900}?chooseShareFormat\(\)/]
  ]) {
    assert.match(panel, what, `${where} does not go through chooseShareFormat`)
  }
  // Nothing may answer a Return by only closing the dialog.
  assert.ok(!/selectedIndex === 0\) root\.shareChooser\.opened = false/.test(panel),
    "the image option still only closes the dialog somewhere")
})

test("Escape cannot be read as a choice of format", () => {
  // `ConfirmDialog.handleKey` emits `canceled()` for Escape without touching
  // `opened`, so routing Escape through it would save an image nobody chose.
  // The key catcher closes the dialog itself and never calls handleKey.
  const keys = blockOf(source["Panel.qml"], "Keys\\.onPressed: function\\(event\\) \\{", 6)
  const escape = keys.indexOf("Qt.Key_Escape")
  const take = keys.indexOf("chooseShareFormat()")
  assert.ok(escape > 0, "Escape is not handled while the chooser is open")
  assert.match(keys.slice(escape, escape + 90), /shareChooser\.opened = false/,
    "Escape does not close the chooser")
  assert.ok(take < 0 || take > escape + 90,
    "Escape shares a map instead of closing the chooser")
  assert.ok(!/handleKey\(/.test(source["Panel.qml"]),
    "something routes Escape through the dialog's own handler, which emits canceled()")
})

test("nothing that belongs to the panel is in the exported picture", () => {
  // Both of these were found by looking at a real exported file, and neither
  // is findable any other way: the code runs, the tests pass, and the defect is
  // only in the artefact.
  //
  // A grab composites the map and its children, so anything drawn over the map
  // for the reader's benefit ends up in the file. A 25%-black progress veil
  // makes every shared frame 25% darker than the map it was taken from, and the
  // map's own buttons put a crosshair and a share glyph in the corner of a
  // picture of a map — the share glyph on top of the export legend.
  const map = readFileSync(join(ROOT, "ui", "MapCanvas.qml"), "utf8")

  assert.ok(!/visible: root\.exporting[\s\S]{0,200}?color: Qt\.rgba\(\s*0,\s*0,\s*0,/.test(map),
    "a translucent overlay bound to `exporting` is composited into every frame")
  assert.ok(!/Qt\.rgba\(\s*0,\s*0,\s*0,\s*0\.2/.test(map),
    "the export veil is still in the map")

  // Both buttons go, not just their handlers.
  for (const glyph of ["Glyphs.RECENTER", "Glyphs.SHARE"]) {
    const button = new RegExp(`Button \\{[\\s\\S]{0,700}?text: ${glyph.replace(".", "\\.")}`).exec(map)
    assert.ok(button, `${glyph} has no button in the map`)
    assert.match(button[0], /visible:[^=]*!root\.exporting/,
      `${glyph} is drawn into the exported picture`)
  }
})

test("the chooser takes the keyboard while it is open", () => {
  // The key catcher is what holds the focus, and it turns keys into meanings —
  // scrub, zoom, play. Over a question about which file to write, "p" must not
  // start a second share underneath the first and the arrows must not scrub the
  // map out from under the question.
  const text = blockOf(source["Panel.qml"], "Keys\\.onPressed: function\\(event\\) \\{", 6)
  assert.match(text, /if \(shareChooser\.opened\)/,
    "the keys handler does not give the chooser the keyboard")
  assert.match(text, /shareChooser\.opened[\s\S]{0,400}?Qt\.Key_Escape/,
    "Escape does not dismiss the chooser")
  assert.match(text, /Qt\.Key_Left[\s\S]{0,200}?Qt\.Key_Right/,
    "the chooser's two options cannot be moved between with the keyboard")
})
