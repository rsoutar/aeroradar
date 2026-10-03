import QtQuick
import Quickshell
import Quickshell.Io
import "lib/Glyphs.js" as Glyphs
import "lib/Alerts.js" as Alerts
import "lib/Basemap.js" as Basemap
import "lib/CamsModel.js" as CamsModel
import "lib/RadarModel.js" as RadarModel
import "lib/Settings.js" as Settings
import "lib/Share.js" as Share

// Headless singleton behind akash.
//
// A bar widget is instantiated once per monitor, so anything that polls lives
// here: the shell mounts exactly one service per plugin, which keeps a
// two-monitor setup from doubling every request.
//
// Responsibilities:
//   1. Own the RainViewer frame manifest (fetched only while a map is open).
//      The property is `radarManifest`, not `manifest` — the shell assigns
//      the plugin's own manifest.json to any service exposing a property by
//      that name.
//   2. Own the decoded basemap, for the same once-per-plugin reason.
//   3. Decide whether to warn about approaching weather, and say so once.
//      A point forecast rather than the radar image: distance alone does not
//      mean approaching, and the forecast carries the instability indices
//      that separate ordinary rain from a severe storm. The radar is the
//      better picture; the forecast is the better trigger.
Item {
  id: root

  property var settings: ({})

  // Path to a bundled file, with the file:// prefix a resolved URL carries.
  function pluginFile(name) {
    return Qt.resolvedUrl(name).toString().replace("file://", "")
  }

  // ---------------------------------------------------------------------------
  // Alert configuration
  // ---------------------------------------------------------------------------

  // Coercion lives in Settings.js, which the panel reads through as well.
  // Clamping the same value in two places is two chances to disagree about it,
  // and the pair that would disagree here decides what gets a notification.
  readonly property bool settingsReady: Settings.isReady(settings)
  readonly property bool alertsEnabled: Settings.alertsEnabled(settings)
  readonly property int alertRadiusKm: Settings.alertRadiusKm(settings)
  readonly property string alertThreshold: Settings.alertThreshold(settings)

  // The radius doubles as lead time — the conversion assumes a storm speed and
  // lives in Alerts.js with the bands it feeds. One setting therefore controls
  // both the ring drawn on the map and how far ahead the forecast is inspected.
  readonly property int leadMinutes: Alerts.leadMinutesFor(alertRadiusKm)
  readonly property int forecastSlots: Alerts.forecastSlotsFor(leadMinutes)

  // ---------------------------------------------------------------------------
  // Location
  // ---------------------------------------------------------------------------

  // Shared with the stock weather widget, which owns the file. Watching it
  // means changing city through the Omarchy menu re-centres the radar live.
  //
  // Read whole, without a ceiling, deliberately: this is Omarchy's own state
  // file, read exactly as Omarchy's own weather panel reads it — same FileView,
  // same watch. omarchy-weather-location writes the file and notifies nobody,
  // so the watch is the only mechanism there is. Every stream this plugin
  // owns is bounded (see the test suite for the inventory).
  //
  // The watch only reaches as far as the containing directory. On a machine
  // where no weather location was ever set, `~/.local/state/omarchy/settings/`
  // does not exist, so a file appearing there later is invisible — hence
  // reloadLocation() and the retry timer beneath it.
  property var location: ({ name: "", latitude: null, longitude: null, valid: false })

  readonly property bool hasLocation: location && location.valid === true
  readonly property string locationName: location ? location.name : ""

  // "ready", "unresolved" or "unset" — see RadarModel.locationState. The middle
  // one is a name typed with no city picked behind it, which the shared file
  // stores happily and this plugin can do nothing with.
  readonly property string locationState: RadarModel.locationState(location)

  FileView {
    id: locationFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.location = RadarModel.parseLocationFile(text())
    onLoadFailed: root.location = RadarModel.parseLocationFile("")
  }

  // Re-read now rather than waiting for the watch. Whoever writes the location
  // calls this immediately afterwards — the only way the first one to exist is
  // ever noticed.
  function reloadLocation() {
    locationFile.reload()
  }

  // Bridges the one window the watch cannot: before any location has ever been
  // stored, the settings directory does not exist and nothing announces a file
  // created in it. Runs fast at first, then slowly forever rather than
  // stopping — stopping would strand the machine it exists for, since being
  // without a location is an ordinary long-lived state and re-entering it
  // should not restart rapid polling. A read a minute apart is a file stat.
  property int locationRetries: 0
  readonly property int locationRetryBurst: 24

  Timer {
    interval: root.locationRetries < root.locationRetryBurst ? 5000 : 60000
    repeat: true
    running: !root.hasLocation
    triggeredOnStart: true
    onTriggered: {
      if (root.locationRetries < root.locationRetryBurst) root.locationRetries++
      locationFile.reload()
    }
  }

  // Identity of the configured place, and what "changed" is measured against.
  // Watching `hasLocation` misses a move (one valid city to another never
  // flips it); watching the `location` object misfires (parseLocationFile
  // returns a fresh object per read, and QML notifies on assignment, so
  // re-reading an unchanged file looks like relocating). Comparing values is
  // what makes "changed" mean changed.
  property string locationKey: ""

  onLocationChanged: {
    var key = hasLocation ? location.latitude + "," + location.longitude + "|" + locationName : ""
    if (key === locationKey) return

    // Learning where we are is not the same as moving; only the latter
    // re-arms. Startup can complete a check before this handler runs, and
    // treating an empty previous key as relocation would announce the same
    // weather twice.
    var moved = locationKey !== ""
    locationKey = key

    coverageChecked = false
    hasCoverage = true

    if (moved) {
      // Somewhere new has not been reported on yet. Without this the latch
      // carries across the move.
      notifiedLevel = 0
      discardReading()
      // A new place's air is a different question; the reading in hand is
      // about the old one. The fetch floor does not apply to a move.
      aqLastFetchMs = 0
    }

    if (hasLocation && alertsEnabled) checkNow()
    if (hasLocation) probeAq()
  }

  // ---------------------------------------------------------------------------
  // RainViewer frame manifest
  // ---------------------------------------------------------------------------

  property var radarManifest: null
  property int frameConsumers: 0
  property int frameFailures: 0

  readonly property var frames: radarManifest ? radarManifest.past : []
  readonly property string tileHost: radarManifest ? radarManifest.host : ""
  readonly property int latestFrameTime: {
    var frame = RadarModel.latestFrame(radarManifest)
    return frame ? frame.time : 0
  }

  // How long ago the newest radar picture was published, for the header's
  // "latest update" readout. The nowTick reference is what makes the binding
  // re-evaluate as time passes; the property would otherwise freeze at the
  // answer startup computed and grow stale for as long as the manifest sat
  // still.
  readonly property string latestUpdateAge: root.latestFrameTime > 0 && root.nowTick >= 0
    ? RadarModel.formatUpdateAge(root.latestFrameTime, Date.now()) : ""

  // Whether the newest frame in hand is one RainViewer could still improve on.
  // Frames publish about every ten minutes, so one younger than that is the
  // newest that exists. A function, not a binding: the answer depends on the
  // passing of time, and a binding would freeze at "current" for exactly as
  // long as it stayed out of date. A frame newer than now means the clock
  // moved backwards, not that RainViewer published into the future — the safe
  // answer is to go and ask.
  function manifestIsCurrent() {
    if (!radarManifest) return false
    var age = Date.now() / 1000 - latestFrameTime
    return age >= 0 && age < RadarModel.FRAME_INTERVAL_SEC
  }

  // Refcounted rather than boolean, so two monitors showing the map do not
  // fight over whether fetching should stop.
  function acquireManifest() {
    frameConsumers++
    loadBasemap()
    ensureCams()
    refreshManifest()
  }

  function releaseManifest() {
    frameConsumers = Math.max(0, frameConsumers - 1)
  }

  // Every manifest request passes through here, so this is where "is it worth
  // asking" belongs. Three reasons not to: one already in flight, the frames
  // in hand already the newest published, or the last attempt too recent to
  // have changed anything.
  readonly property int minFetchGapMs: 60000
  property real lastManifestFetchMs: 0

  function refreshManifest() {
    if (manifestProc.running) return
    if (manifestIsCurrent()) return

    var now = Date.now()
    // A request stamped in the future is a clock that moved; left alone it
    // would refuse every fetch until real time caught up.
    if (lastManifestFetchMs > now) lastManifestFetchMs = 0

    // The floor bounds what opening and closing the map repeatedly can cost,
    // and guards frames already on screen. A closed-and-reopened empty map is
    // a request to retry; a minute of silence is not an answer to that.
    if (radarManifest && lastManifestFetchMs > 0 && now - lastManifestFetchMs < minFetchGapMs) return

    lastManifestFetchMs = now
    manifestProc.launch(RadarModel.manifestCommand())
  }

  BoundedProcess {
    id: manifestProc
    onResponded: function(exitCode, text) { root.applyManifestResponse(exitCode, text) }
  }

  function applyManifestResponse(exitCode, text) {
    // Keep the previous manifest on any failure: stale frames still render,
    // and the next tick retries. Blanking the map on one failed request would
    // be worse than showing data a few minutes old.
    if (exitCode !== 0) {
      frameFailures++
      return
    }
    var parsed = RadarModel.parseManifest(text)
    if (!parsed) {
      frameFailures++
      return
    }
    frameFailures = 0
    radarManifest = parsed
  }

  // ---------------------------------------------------------------------------
  // Basemap
  // ---------------------------------------------------------------------------

  // The ground the radar is drawn on, decoded once for the whole session. It
  // lives here rather than in the panel because a bar widget is built once per
  // monitor, and two screens showing the map would otherwise each hold their
  // own copy of the coastline. Read on first use, so a session that never
  // opens the map never pays for it.
  //
  // The geometry ships with the plugin instead of arriving as tiles — a
  // keyless tile endpoint is a policy rather than a property, and geometry in
  // the repository cannot be withdrawn or rate-limited, and works with no
  // network at all.
  //
  // Also read whole, without a ceiling: it is this plugin's own file, inside
  // its own directory, so a ceiling here would guard nothing. Corruption is
  // handled instead — the decoder answers null on anything it cannot read.
  //
  // Decoding spreads over many short steps rather than one call, because this
  // is the thread that draws the bar, every panel and the lock screen, and one
  // call holds it for over half a second on a fast machine and seconds on a
  // slow one. Each layer is published as it completes, so the ground arrives
  // land-first over a second or so during which the radar is already drawn.
  property var basemap: null
  property bool basemapFailed: false
  property var basemapDecoder: null

  // The decoded geometry, kept across shell restarts. The decode costs the
  // shell most of a second on the first map open of every session, and the
  // ground only changes when the plugin does, so the arrays are written out
  // once and read back as views over one buffer. It lives beside caps.json in
  // the plugin's own directory; the cache is never an authority, and anything
  // unreadable falls through to decoding data/basemap.bin as before.
  //
  // lib/Basemap.js owns the format, and stamps every cache with the digest of
  // data/basemap.bin from lib/BasemapDigest.js: rebuilding the ground changes
  // the digest, so a stale cache is refused with nothing to bump by hand.
  readonly property string basemapCachePath: camsConfigDir + "/basemap.cache"

  // Set once the cache has been consulted, so a missing one does not send
  // loadBasemap() round again.
  property bool basemapStarted: false

  function loadBasemap() {
    if (basemap || basemapStarted) return
    basemapStarted = true
    basemapCacheFile.path = basemapCachePath
  }

  FileView {
    id: basemapCacheFile
    path: ""
    // A missing cache is the common first run, not a fault worth logging.
    printErrors: false
    // QSaveFile: a temp file in the same directory, renamed over the target,
    // so a symlink planted at the cache's name is replaced rather than
    // followed. The cache is not private, so the 0644 it lands with is fine.
    atomicWrites: true
    onLoaded: {
      var cached = Basemap.deserializeCache(basemapCacheFile.data())
      if (cached !== null) {
        root.basemap = cached
        root.basemapFailed = false
      } else {
        root.decodeBasemap()
      }
    }
    onLoadFailed: root.decodeBasemap()
  }

  function decodeBasemap() {
    if (basemap || basemapFile.path !== "") return
    basemapFile.path = pluginFile("data/basemap.bin")
  }

  FileView {
    id: basemapFile
    path: ""
    onLoaded: {
      root.basemapDecoder = Basemap.beginDecode(basemapFile.data())
      if (root.basemapDecoder === null) root.basemapUnreadable("could not be decoded")
    }
    onLoadFailed: root.basemapUnreadable("could not be read")
  }

  function basemapUnreadable(why) {
    root.basemapDecoder = null
    root.basemap = null
    root.basemapFailed = true
    console.warn("akash: data/basemap.bin " + why)
  }

  // One step per frame, for as long as there is a decoder. A QML Timer is
  // driven by the animation clock: an interval of one millisecond fires once
  // per frame, so a step runs, the frame is drawn, and input and the IPC the
  // shell answers on this thread get their turn in between.
  Timer {
    id: basemapStepper
    interval: 1
    repeat: true
    running: root.basemapDecoder !== null
    onTriggered: {
      var decoder = root.basemapDecoder
      var layersBefore = decoder.order.length
      var finished = decoder.step(Basemap.DECODE_STEP_MS)

      if (finished) {
        if (decoder.result === null) {
          root.basemapUnreadable("could not be decoded")
          return
        }
        root.basemap = decoder.result
        root.basemapFailed = false
        root.basemapDecoder = null
        // The cache is written once the ground has been on screen for a
        // moment, never in the frame that draws it: the encode copies several
        // megabytes, and this is the thread that draws everything.
        basemapCacheWriter.restart()
      } else if (decoder.order.length !== layersBefore) {
        root.basemap = decoder.partial()
      }
    }
  }

  // Writes the decoded ground to the cache, a second after it was drawn. It
  // runs only after a decode — a cache that read back cleanly is already the
  // answer — so this costs one encode per plugin version, not one per session.
  Timer {
    id: basemapCacheWriter
    interval: 1000
    repeat: false
    onTriggered: basemapCacheFile.setData(Basemap.serializeCache(root.basemap))
  }

  // ---------------------------------------------------------------------------
  // CAMS capabilities and state
  // ---------------------------------------------------------------------------

  // cams.py's files: the layer registry the panel's chips are built from, and
  // the state file that says which region we are in. The helper refreshes the
  // cache when stale (6 h) and writes both; the service reads them and exposes
  // the parsed forms. Owned here rather than in the panel for the same reason
  // as the basemap: two monitors share one copy.
  //
  // The readers point at the files now, not after init: a cache left by an
  // earlier session renders the chips the moment the service exists, so the
  // panel opens onto the familiar picker instead of a lone Radar chip that
  // fills in only when the subprocess happens to be done. watchChanges then
  // swaps in whatever init refreshes — a stale cache is still the best answer
  // until the fresh one lands, the same policy as the radar frames.
  //
  // Read whole, without a ceiling, like the basemap — they are this plugin's
  // own files, inside its own directory. Corruption is handled: an unparseable
  // cache reads as null, and the panel answers with no CAMS categories rather
  // than a broken picker.
  property var camsCaps: null
  property var camsState: null
  readonly property string camsRegion: camsState ? String(camsState.region || "europe") : "europe"
  readonly property string camsConfigDir: Quickshell.env("HOME") + "/.config/omarchy/akash"

  // Whether init has been offered this session. The cached files load by
  // themselves, but the six-hour staleness refresh still has to happen once,
  // so the first acquire decides. Reset on a process that never forked, so a
  // transient failure can be retried.
  property bool camsWarmed: false

  function ensureCams() {
    if (camsWarmed || camsInitProc.running) return
    camsWarmed = true
    camsInitProc.launch(["python3", pluginFile("cams.py"), "init"])
  }

  BoundedProcess {
    id: camsInitProc
    onResponded: function(exitCode, text) {
      // The files the helper wrote (or left from an earlier session) are the
      // real answer; read them whether or not the refresh itself was clean.
      // Re-pointing also covers the machine where this directory did not
      // exist at startup: the creation the helper just made is invisible to a
      // watch never established, and setting the path re-reads and re-watches.
      camsCapsFile.path = root.camsConfigDir + "/caps.json"
      camsStateFile.path = root.camsConfigDir + "/state.json"
      if (exitCode !== 0) {
        if (exitCode === -1) root.camsWarmed = false
        console.warn("akash: cams.py init failed (" + exitCode + ")")
      }
    }
  }

  FileView {
    id: camsCapsFile
    path: root.camsConfigDir + "/caps.json"
    watchChanges: true
    onLoaded: {
      try {
        root.camsCaps = JSON.parse(text())
      } catch (e) {
        root.camsCaps = null
        console.warn("akash: caps.json could not be parsed")
      }
    }
    onLoadFailed: root.camsCaps = null
  }

  FileView {
    id: camsStateFile
    path: root.camsConfigDir + "/state.json"
    watchChanges: true
    onLoaded: {
      try {
        root.camsState = JSON.parse(text())
      } catch (e) {
        root.camsState = null
      }
    }
    onLoadFailed: root.camsState = null
  }

  // ---------------------------------------------------------------------------
  // Air-quality readout for the bar
  // ---------------------------------------------------------------------------

  // A point value for the tracked layer at home, from WMS GetFeatureInfo via
  // cams.py. This is what the bar pill renders and what the air-quality alert
  // (later) judges. CAMS is a forecast grid, not a station network, so the
  // value is a neighbourhood reading — the model cell, not the street.
  //
  // The layer is the state file's `barMetric` (default PM2.5), deliberately
  // not the overlay's current layer: a pill that changes species because the
  // user was browsing pollen yesterday is a pill that says nothing.
  readonly property string aqMetricLayer: {
    if (camsState && camsState.barMetric) return String(camsState.barMetric)
    return camsRegion === "europe"
      ? "composition_europe_pm2p5_forecast_surface"
      : "composition_pm2p5"
  }

  // Where the reading is taken. The weather location when it has coordinates;
  // otherwise the timezone centre from the state file, which is coarse but
  // honest — better a country-level value than no value, and it exists on a
  // machine that never set a city.
  function aqHomePoint() {
    if (hasLocation) {
      var la = parseFloat(location.latitude)
      var lo = parseFloat(location.longitude)
      if (isFinite(la) && isFinite(lo)) return { lat: la, lon: lo }
    }
    var home = camsState ? camsState.home : null
    if (home) {
      var hla = parseFloat(home.lat)
      var hlo = parseFloat(home.lon)
      if (isFinite(hla) && isFinite(hlo)) return { lat: hla, lon: hlo }
    }
    return null
  }

  property string aqLayerName: ""
  property real aqValue: NaN
  property string aqUnit: ""
  property double aqCheckTime: 0
  property bool aqChecking: false
  property int aqFailures: 0

  // The worst band across the probe window, and the wall-clock time it lands.
  // The pill reads the current value; the alert judges the window.
  property int aqWorstBand: -1
  property string aqWorstClock: ""

  // The band the user was last told about — the air-quality half of the
  // latch. Held until conditions clear so a multi-day episode does not
  // notify hourly, while a worsening band still escalates.
  property int aqNotifiedBand: 0

  // Alert configuration, coerced in Settings.js like the storm half's.
  readonly property bool aqAlertsEnabled: Settings.aqAlertsEnabled(settings)
  readonly property int aqThresholdBand: Settings.aqThresholdBand(settings)

  readonly property var aqLayer: CamsModel.findLayer(camsCaps, aqLayerName)
  readonly property var aqLevel: aqLayer ? CamsModel.aqLevel(aqLayer.species, aqValue) : null

  // A reading more than two model cycles old is marked rather than trusted.
  // `nowTick` exists so the comparison re-evaluates: a plain binding over
  // Date.now() would freeze at whatever the first evaluation saw.
  property int nowTick: 0
  readonly property bool aqStale: aqCheckTime > 0
    && (Date.now() - aqCheckTime) > 2 * 3600 * 1000 && nowTick >= 0

  // The tracked layer's species key, "" until one is attached. Everything that
  // classifies a reading passes this rather than re-testing aqLayer.
  readonly property string aqSpecies: aqLayer ? String(aqLayer.species || "") : ""

  // The probe answer, cleaned for reading and printing. NaN while no reading
  // is in hand.
  readonly property double aqValueRounded: isFinite(aqValue) ? Math.round(aqValue * 10) / 10 : NaN

  // "PM2.5 9.6 µg/m3 · Poor" — the tooltip and the pill's reason to exist.
  // Empty until a real reading is in hand: a "…" that never resolves and an
  // error that renders as a value are both silences dressed as answers.
  readonly property string aqSummary: {
    if (!aqLayer || !isFinite(aqValue)) return ""
    var text = aqLayer.short + " " + aqValueRounded + (aqUnit !== "" ? " " + aqUnit : "")
    return aqLevel ? text + " · " + aqLevel.name : text
  }

  // Just the figure for the pill itself; the full summary goes in the tooltip.
  readonly property string aqPillText: {
    if (!isFinite(aqValue)) return ""
    return aqValueRounded + (aqUnit !== "" ? " " + aqUnit : "")
  }

  // The CAMS model does not update faster than about an hour, so a probe
  // inside that window would re-fetch bytes that cannot have changed. The
  // floor also bounds what location flapping can cost.
  readonly property int aqMinGapMs: 600000
  property double aqLastFetchMs: 0

  // The horizon the alert looks over: now plus the next few forecast steps.
  // Air quality evolves over hours, not minutes, so a short window catches
  // the episode without pretending to a storm-style lead time.
  readonly property int aqHorizonSteps: 3

  function probeAq() {
    if (aqProc.running) return
    if (!camsState) return  // no region, no home fallback, no metric yet
    var layer = aqMetricLayer
    var point = aqHomePoint()
    if (layer === "" || !point) return

    var now = Date.now()
    if (aqLastFetchMs > now) aqLastFetchMs = 0
    if (aqLastFetchMs > 0 && now - aqLastFetchMs < aqMinGapMs) return

    aqLastFetchMs = now
    aqChecking = true
    var script = pluginFile("cams.py")
    var command = ["python3", script, "probe",
                   "--layer", layer,
                   "--lat", String(point.lat),
                   "--lon", String(point.lon)]

    // The near-term steps, so the alert can say what is coming rather than
    // only what is. The step nearest now travels without an explicit time —
    // the server's default — and the rest explicitly.
    var record = CamsModel.findLayer(camsCaps, layer)
    if (record) {
      var steps = CamsModel.layerSteps(record)
      if (steps.length > 0) {
        var nearest = CamsModel.nearestTimeIndex(steps)
        for (var i = 1; i <= aqHorizonSteps && nearest + i < steps.length; i++) {
          command.push("--time")
          command.push(steps[nearest + i])
        }
      }
    }
    aqProc.launch(command)
  }

  // Asked from the panel when it opens: a reading older than the model's own
  // cadence is refreshed rather than trusted.
  function refreshAqIfStale() {
    if (aqProc.running) return
    if (aqCheckTime > 0 && Date.now() - aqCheckTime < RadarModel.FRAME_INTERVAL_SEC * 6 * 1000) return
    aqLastFetchMs = 0
    probeAq()
  }

  BoundedProcess {
    id: aqProc
    onResponded: function(exitCode, text) {
      root.aqChecking = false
      if (exitCode !== 0) {
        root.aqFailures++
        return
      }
      var parsed
      try {
        parsed = JSON.parse(String(text || "").trim())
      } catch (e) {
        root.aqFailures++
        return
      }
      var results = parsed && parsed.results ? parsed.results : []
      var current = results.length > 0 ? results[0] : null
      // value null is a real answer — no coverage, a renamed layer, a
      // ServiceException. Counting it a failure would retry forever; showing
      // it as a value would be lying. It is neither: the old reading stands.
      if (!current || current.value === null || current.value === undefined
          || !isFinite(current.value)) {
        root.aqFailures++
        return
      }
      root.aqFailures = 0
      root.aqLayerName = root.aqMetricLayer
      root.aqValue = current.value
      root.aqUnit = String(current.unit || "")
      root.aqCheckTime = Date.now()

      // Worst band across the window, judged against the layer's own
      // thresholds, with the wall-clock time it lands at.
      var worst = -1
      var worstClock = ""
      for (var i = 0; i < results.length; i++) {
        var entry = results[i]
        if (entry.value === null || entry.value === undefined || !isFinite(entry.value)) continue
        var band = CamsModel.aqBandIndex(root.aqSpecies, entry.value)
        if (band > worst) {
          worst = band
          worstClock = entry.time !== "" ? Alerts.clockFromTimestamp(Date.parse(entry.time) / 1000) : ""
        }
      }
      root.aqWorstBand = worst
      root.aqWorstClock = worstClock
      root.evaluateAqAlert()
    }
    onCancelled: function() { root.aqChecking = false }
  }

  // ---------------------------------------------------------------------------
  // Air-quality alerting
  // ---------------------------------------------------------------------------

  function evaluateAqAlert() {
    if (aqWorstBand < 0) return  // nothing in hand to judge
    var decision = Alerts.decide(aqWorstBand, aqThresholdBand, aqNotifiedBand, aqAlertsEnabled)
    aqNotifiedBand = decision.notified
    if (decision.notify) notifyAq()
  }

  function notifyAq() {
    var level = CamsModel.aqLevel(aqSpecies, aqValue)
    if (!level) return
    var text = Alerts.aqNotificationText({
      band: aqWorstBand,
      bandName: CamsModel.BAND_NAMES[aqWorstBand] || level.name,
      currentBand: CamsModel.aqBandIndex(aqSpecies, aqValue),
      worstBand: aqWorstBand,
      worstBandName: CamsModel.BAND_NAMES[aqWorstBand] || "",
      worstClock: aqWorstClock,
      layerShort: aqLayer.short,
      value: aqValueRounded,
      unit: aqUnit
    }, locationName)

    // Same delivery rules as the storm toast: CLI-style so it can pass Do
    // Not Disturb when critical, no click action, the plugin's own glyph.
    notifyProc.command = [
      "omarchy-notification-send",
      "--app-name", "Akash",
      "-g", Glyphs.RADAR,
      "-u", text.urgency,
      text.headline,
      text.description
    ]
    notifyProc.running = true
  }

  // The probe only knows the region once the state file has been read; the
  // first correct probe follows it, and the earlier fallback — which for a
  // non-European timezone would have asked the wrong layer — is superseded.
  onCamsStateChanged: {
    aqLastFetchMs = 0
    probeAq()
  }

  // Changing the threshold or the toggle re-arms the air-quality latch the
  // same deliberate-act rule as the storm's: a decision deserves the current
  // answer, not ten minutes or an hour of silence. Both are ignored the first
  // time they settle, because settings arrive after construction.
  property int appliedAqThreshold: -1
  property bool appliedAqEnabled: false

  onAqThresholdBandChanged: applyAqConfig()
  onAqAlertsEnabledChanged: applyAqConfig()

  function applyAqConfig() {
    Qt.callLater(syncAqConfig)
  }

  function syncAqConfig() {
    if (!settingsReady) return

    var first = appliedAqThreshold === -1
    var thresholdMoved = !first && appliedAqThreshold !== aqThresholdBand
    var toggled = !first && appliedAqEnabled !== aqAlertsEnabled

    appliedAqThreshold = aqThresholdBand
    appliedAqEnabled = aqAlertsEnabled

    if (first || (!thresholdMoved && !toggled)) return

    aqNotifiedBand = 0
    if (!aqAlertsEnabled) {
      // Off must stop the work, not hide it: a probe in flight is cancelled,
      // and its cancellation is not a failure.
      if (aqProc.running) aqProc.cancelRequested = true
      aqProc.running = false
      aqChecking = false
    } else {
      evaluateAqAlert()
    }
  }

  // One probe per hour — the model cadence, not a polling instinct.
  Timer {
    id: aqTimer
    interval: 3600000
    repeat: true
    running: aqMetricLayer !== "" && aqHomePoint() !== null
    triggeredOnStart: true
    onTriggered: root.probeAq()
  }

  // Refreshes the staleness binding once a minute. Nothing polls; this only
  // re-renders a boolean that is otherwise frozen at startup's answer.
  Timer {
    interval: 60000
    repeat: true
    running: true
    onTriggered: root.nowTick++
  }

  // ---------------------------------------------------------------------------
  // Radar coverage
  // ---------------------------------------------------------------------------

  // Whether a ground radar reaches the configured location. Large parts of the
  // world have none, and an empty map there reads as a broken plugin unless it
  // says so. Resolved by the panel, which can decode images; this service
  // only remembers the answer.
  property bool coverageChecked: false
  property bool hasCoverage: true

  function reportCoverage(covered) {
    coverageChecked = true
    hasCoverage = covered === true
  }

  // ---------------------------------------------------------------------------
  // Reporting a finished share
  // ---------------------------------------------------------------------------

  // The panel does the capturing; this is where the toast comes from, because
  // there is one notification channel in this plugin and adding a second would
  // mean two processes racing to own the same toast. `reportCoverage` above is
  // the same arrangement for the same reason.
  //
  // `why` is the share helper's own sentence, collected from its stderr because
  // a share that fails with only "it did not save" is a support ticket waiting
  // to happen. It is bounded and stripped in the panel before it gets here —
  // `Share.plain` — and this function adds the cap, because the body is a
  // markup-capable sink and the cap belongs at the sink too.
  //
  // No click action, for the reason the storm toast has none: a click means "I
  // have seen this", and spending it on opening a file manager answers a
  // question the reader did not ask. The path is in the body instead, and the
  // clipboard already holds the picture itself.
  readonly property int shareWhyMax: 200
  function reportShare(headline, ok, why) {
    notifyProc.command = [
      "omarchy-notification-send",
      "--app-name", "Akash",
      "-g", Glyphs.SHARE,
      // A share that failed says so at normal volume. A critical toast is
      // reserved here for the storm and air-quality alerts, and spending it on
      // a failed export teaches people to ignore it.
      "-u", "normal",
      headline,
      ok ? "The map is also on your clipboard."
        : Share.plain(why).slice(0, shareWhyMax)
    ]
    notifyProc.running = true
  }

  // ---------------------------------------------------------------------------
  // Forecast polling
  // ---------------------------------------------------------------------------

  // When a check last produced an outlook, and when one last came back at all.
  // Different questions: a request that fails, or answers with nothing usable,
  // still happened. Without the second, "has not run yet" and "ran and could
  // not tell you anything" look identical — and the failure backoff can make
  // the first last an hour.
  property double lastCheckTime: 0
  property double lastAnswerTime: 0
  property bool checking: false
  property int consecutiveFailures: 0

  // Any network work still in flight, so the panel header can say "Fetching"
  // instead of "Live". A notification is not a fetch, so notifyProc is not
  // counted.
  readonly property bool fetching: manifestProc.running || camsInitProc.running || aqProc.running || forecastProc.running

  // Highest severity inside the lead window: 0 clear, 1 light, 2 moderate,
  // 3 heavy, 4 severe.
  property int outlookLevel: 0
  property int outlookLeadMinutes: 0

  // Wall-clock time the weather is expected, as "HH:MM". A relative figure
  // goes stale the moment it is written; the clock time stays true however
  // long the notification sits there.
  property string outlookAtClock: ""
  property real outlookPrecipitation: 0
  property real outlookCape: 0
  property real outlookGust: 0

  readonly property string outlookLabel: Alerts.levelName(outlookLevel)

  // Everything the last check said, dropped together. Clearing the outlook
  // while leaving the timestamp behind would leave fair weather asserted for
  // a city that has never been checked.
  function discardReading() {
    outlookLevel = 0
    outlookLeadMinutes = 0
    outlookAtClock = ""
    outlookPrecipitation = 0
    outlookCape = 0
    outlookGust = 0
    lastCheckTime = 0
  }

  // Everything the watch was told about, dropped together: the reading, the
  // latch, and any check in flight. Used when the watch is turned off or the
  // place moved — states in which "what I was last told" answers nothing.
  function resetWatch() {
    notifiedLevel = 0
    discardReading()
    if (forecastProc.running) forecastProc.cancelRequested = true
    forecastProc.running = false
    checking = false
  }

  // Retried from the panel when it opens; see Alerts.shouldRetryForecast for
  // why only a failing check is retried. Seconds rather than the minute the
  // manifest uses: the person this exists for has just reconnected and
  // reopened the panel, which happens well inside a minute.
  readonly property int minRetryGapMs: 10000

  function refreshIfStale() {
    if (!alertsEnabled || !hasLocation || checking) return
    if (!Alerts.shouldRetryForecast({
      now: Date.now(),
      lastAnswer: lastAnswerTime,
      lastReading: lastCheckTime,
      failing: consecutiveFailures > 0,
      floor: minRetryGapMs,
      cadence: RadarModel.FORECAST_INTERVAL_SEC * 1000
    })) return
    checkNow()
  }

  // What the request in flight was asked about: where, under what name, and
  // over how wide a window. A response is only an answer to the question that
  // was asked, and both halves can move while curl is running. checkNow()
  // refuses a second overlapping request, so the change handlers cannot fix
  // this themselves — comparing here is what notices, and asks again.
  property string requestedFor: ""

  function forecastRequestKey(lat, lon) {
    return lat + "," + lon + "|" + locationName + "|" + forecastSlots
  }

  function checkNow() {
    if (!hasLocation || checking) return

    // parseFloat, not Number: an unset location carries null, Number(null) is
    // 0, and a request built from that would quietly report the weather at
    // 0°N 0°E. Failing loudly beats answering confidently about the wrong
    // hemisphere.
    var lat = parseFloat(location.latitude)
    var lon = parseFloat(location.longitude)
    if (!isFinite(lat) || !isFinite(lon)) return

    checking = true
    requestedFor = forecastRequestKey(lat, lon)

    // Five coordinates rather than one: the centre and four points 5 km out.
    // The model grid is coarse enough that a stored coordinate speaks for an
    // arbitrary patch beside it rather than for the town it names. All five
    // travel in one request.
    var points = RadarModel.samplePoints(lat, lon)
    if (points.length === 0) {
      // Unreachable given the check above, but a guard that returns without
      // clearing `checking` would block every later check for the session.
      checking = false
      return
    }

    // One hour more than the window is wide: each slot is judged against the
    // instability of the hour it falls in, and the slots start at the quarter
    // hour already under way — without the extra one, the last slots have no
    // hour to be judged against and are never promoted.
    forecastProc.launch(RadarModel.forecastCommand(
      points, forecastSlots, Math.max(2, Math.ceil(leadMinutes / 60)) + 1))
  }

  BoundedProcess {
    id: forecastProc
    onResponded: function(exitCode, text) { root.applyForecastResponse(exitCode, text) }
    onCancelled: function() { root.checking = false }
  }

  function applyForecastResponse(exitCode, text) {
    checking = false
    lastAnswerTime = Date.now()

    // Answered a question nobody is asking any more: applying it would report
    // one place's forecast under another's name. What it earns is the request
    // the change never got to make.
    var lat = parseFloat(location.latitude)
    var lon = parseFloat(location.longitude)
    if (requestedFor !== "" && (!isFinite(lat) || !isFinite(lon)
        || forecastRequestKey(lat, lon) !== requestedFor)) {
      requestedFor = ""
      checkNow()
      return
    }
    requestedFor = ""

    if (exitCode !== 0) {
      consecutiveFailures++
      return
    }

    var raw = String(text || "").trim()
    if (raw === "") {
      consecutiveFailures++
      return
    }

    var data
    try {
      data = JSON.parse(raw)
    } catch (e) {
      consecutiveFailures++
      return
    }

    consecutiveFailures = 0
    applyForecast(data)
  }

  function applyForecast(data) {
    var outlook = Alerts.summarizeForecast(data, forecastSlots)
    // Null means the response carried nothing usable. Keeping the previous
    // outlook is right; overwriting it with zeros would report fair weather
    // on the strength of a broken response.
    if (!outlook) return

    outlookCape = outlook.cape
    outlookGust = outlook.gust
    outlookPrecipitation = outlook.precipitation
    outlookLeadMinutes = outlook.leadMinutes
    outlookAtClock = outlook.clock
    outlookLevel = outlook.level
    lastCheckTime = Date.now()

    evaluateAlert()
  }

  // ---------------------------------------------------------------------------
  // Alerting
  // ---------------------------------------------------------------------------

  // The level the user was last told about. Held until conditions clear, so a
  // storm that lingers for three hours does not notify eighteen times, while
  // a situation that worsens still escalates.
  property int notifiedLevel: 0

  function evaluateAlert() {
    var decision = Alerts.decide(outlookLevel, Alerts.levelValue(alertThreshold), notifiedLevel, alertsEnabled)
    notifiedLevel = decision.notified
    if (decision.notify) notify()
  }

  function notify() {
    var text = Alerts.notificationText({
      level: outlookLevel,
      leadMinutes: outlookLeadMinutes,
      clock: outlookAtClock,
      precipitation: outlookPrecipitation,
      cape: outlookCape,
      gust: outlookGust
    }, locationName)

    // Deliberately no click action: a click on a toast means "I have seen
    // this" to almost everyone, and spending that gesture on opening a window
    // answers a question the reader did not ask.
    notifyProc.command = [
      "omarchy-notification-send",
      "--app-name", "Akash",
      // The same glyph the bar widget wears, so the toast is recognisably
      // from this plugin before a word of it is read.
      "-g", Glyphs.RADAR,
      "-u", text.urgency,
      text.headline,
      text.description
    ]
    notifyProc.running = true
  }

  Process {
    id: notifyProc
  }

  // ---------------------------------------------------------------------------
  // Scheduling
  // ---------------------------------------------------------------------------

  // RainViewer publishes a frame every ten minutes and the forecast model
  // updates no faster, so this is both the floor and the natural cadence.
  // Backing off on repeated failure keeps a network outage from becoming a
  // tight retry loop inside a process that lives all day.
  readonly property int baseIntervalMs: RadarModel.FRAME_INTERVAL_SEC * 1000
  readonly property int backoffMultiplier: Math.min(6, Math.pow(2, Math.min(consecutiveFailures, 3)))

  // Two things want this cadence, and either alone is reason enough to run:
  // the alert check, which needs a location, and the map, which needs to be
  // open. The backoff belongs to the alert check alone — nothing about
  // api.open-meteo.com having a bad day says anything about RainViewer, and
  // stretching the map's cadence on that evidence would freeze the picture in
  // front of someone watching it.
  Timer {
    id: pollTimer
    readonly property bool alerting: root.alertsEnabled && root.hasLocation
    readonly property bool watched: root.frameConsumers > 0
    interval: root.baseIntervalMs * (alerting && !watched ? root.backoffMultiplier : 1)
    repeat: true
    running: alerting || watched
    triggeredOnStart: true
    onTriggered: {
      if (alerting) root.checkNow()
      // Frames serve the map and nothing else, so a closed map is not a
      // reason to fetch them — including for the alert, which reads the
      // forecast.
      if (watched) root.refreshManifest()
    }
  }

  // Changing the threshold or the radius is as deliberate as flipping the
  // toggle: re-arm and report the current state rather than leaving the user
  // to wonder for up to ten minutes. The two need different work — a new
  // threshold only changes the question, so the reading in hand is
  // re-evaluated in place; a new radius moves the lead window, so the held
  // reading is about the wrong horizon and must be fetched again. Both are
  // ignored the first time they settle, because settings arrive after the
  // service is constructed: that initial jump is startup, not a decision.
  property string appliedThreshold: ""
  property int appliedRadius: 0

  onAlertThresholdChanged: applyAlertConfig()
  onAlertRadiusKmChanged: applyAlertConfig()
  // Settings arriving re-baseline both watches' config sync in one step.
  onSettingsReadyChanged: { applyAlertConfig(); applyAqConfig() }

  // Coalesced to the end of the turn. Bindings re-evaluate one at a time, so
  // a single settings arrival moves the radius and the threshold in separate
  // steps; comparing at each step would read the second as a decision nobody
  // made. Qt.callLater collapses repeated calls into one.
  function applyAlertConfig() {
    Qt.callLater(syncAlertConfig)
  }

  function syncAlertConfig() {
    if (!settingsReady) return

    var first = appliedThreshold === ""
    var thresholdMoved = !first && appliedThreshold !== alertThreshold
    var radiusMoved = !first && appliedRadius !== alertRadiusKm

    appliedThreshold = alertThreshold
    appliedRadius = alertRadiusKm

    if (first || (!thresholdMoved && !radiusMoved)) return

    notifiedLevel = 0
    if (radiusMoved) {
      if (hasLocation && alertsEnabled) checkNow()
    } else {
      evaluateAlert()
    }
  }

  // Turning alerts off must actually stop the work, not merely hide it.
  onAlertsEnabledChanged: {
    if (!alertsEnabled) resetWatch()
    else if (hasLocation) checkNow()
  }

  // ---------------------------------------------------------------------------
  // Summary for the bar
  // ---------------------------------------------------------------------------

  readonly property string barSummary: {
    if (!hasLocation) return ""
    if (!alertsEnabled) return ""
    // No reading at all while checks are failing is not fair weather.
    // "clear" there would be the plugin's own silence dressed up as an answer.
    if (lastCheckTime <= 0) return consecutiveFailures > 0 ? "unavailable" : ""
    if (outlookLevel === 0) return "clear"
    // Clock rather than countdown: the label only refreshes when a check
    // runs, so a relative figure would be up to ten minutes stale on screen.
    var when = outlookAtClock !== "" ? outlookAtClock
      : (outlookLeadMinutes <= 0 ? "now" : Alerts.humanizeMinutes(outlookLeadMinutes))
    return outlookLabel.toLowerCase() + " " + when
  }
}
