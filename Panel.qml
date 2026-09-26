import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ui"
import "lib/Alerts.js" as Alerts
import "lib/CamsModel.js" as CamsModel
import "lib/Frames.js" as Frames
import "lib/Glyphs.js" as Glyphs
import "lib/Settings.js" as Settings
import "lib/Share.js" as Share
import "lib/TileMath.js" as TileMath
import "lib/RadarModel.js" as RadarModel

// The akash panel.
//
// Opens centred on the location Omarchy already knows about, stacks the
// latest radar frame over a basemap, and can play the last two hours as a
// loop. The alert toggle lives down here, so turning the watch on is one
// click from the thing you are looking at — and because a schema entry is
// not an interface: nothing in the installed shell renders one, so a control
// that is not in a panel is nowhere.
//
// This file owns the state the pieces in ui/ share — where the map is
// looking, which frame is on screen, what is being edited — plus the
// lifecycle, the keyboard map and the IPC surface. Everything drawn is a
// component in ui/; everything computed is a function in lib/.
Panel {
  id: root
  moduleName: "akash"
  ipcTarget: "akash"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  // The bar tracks the widget in its slot, not this nested panel, so anything
  // the popout coordinator compares against has to be the widget.
  readonly property var barIdentity: hostWidget || root

  // Path to a bundled file, with the file:// prefix a resolved URL carries.
  // The same shape Service.qml uses, for the same reason: a path assembled out
  // of a home directory is a path that follows wherever it was planted, and
  // the plugin's own directory is the one place that is not.
  function pluginFile(name) {
    return Qt.resolvedUrl(name).toString().replace("file://", "")
  }

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  // Every reading goes through Settings.js, which the service reads through
  // as well, so the panel and the alert that fires from it cannot disagree
  // about what the user configured.
  readonly property bool alertsEnabled: Settings.alertsEnabled(settings)
  readonly property int alertRadiusKm: Settings.alertRadiusKm(settings)
  readonly property var radiusPresets: Settings.radiusPresets(alertRadiusKm)
  readonly property string alertThreshold: Settings.alertThreshold(settings)
  readonly property var thresholdOptions: Alerts.THRESHOLD_OPTIONS
  readonly property bool aqAlertsEnabled: Settings.aqAlertsEnabled(settings)
  readonly property string aqBandName: {
    var band = Settings.aqThresholdBand(settings)
    return band >= 0 && band < CamsModel.BAND_NAMES.length ? CamsModel.BAND_NAMES[band] : "Poor"
  }
  // Alerts below Moderate are noise: the EEA's own band-1 days are most days
  // in most places, and a watch that fires daily is switched off. The options
  // are the band ladder's top four, so every string names a real band.
  readonly property var aqBandOptions: CamsModel.BAND_NAMES.slice(2)
  readonly property bool smoothTiles: Settings.smoothTiles(settings)
  readonly property bool showSnow: Settings.showSnow(settings)
  readonly property int colorSchemeId: Settings.colorSchemeId(settings)
  readonly property string defaultView: Settings.defaultView(settings)

  // The service is the authority on lead time whenever it is mounted; the
  // fallback covers the moment before it is.
  readonly property int alertLeadMinutes: service ? service.leadMinutes : Alerts.leadMinutesFor(alertRadiusKm)

  // Write one field back to this widget's inline shell.json entry, preserving
  // every other field. Same approach the first-party panels use.
  function persistSetting(key, value) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var existing in settings) if (existing !== "id") entry[existing] = settings[existing]
    entry[key] = value
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ---------------------------------------------------------------------------
  // Settings page
  // ---------------------------------------------------------------------------
  //
  // The rest of the manifest's preferences that the panel does not otherwise
  // expose, gathered into a dedicated settings page like oma.quake's: the "S"
  // key or the hint-cap at the foot of the panel opens it, the page replaces
  // the map column while it is open, and it is the only home these values have
  // — the alert controls that already live in their own sections are not
  // repeated here.

  property bool settingsOpen: false

  readonly property int defaultZoomSetting: Settings.defaultZoom(settings)
  readonly property bool showLabelInBar: Settings.showLabel(settings)
  readonly property var viewOptions: Settings.VIEW_OPTIONS
  readonly property color settingsForeground: root.bar ? root.bar.foreground : Color.foreground

  // A field owns the keys while it is focused — otherwise typing "s" to toggle
  // the page would fire in the middle of an edit. The location picker and the
  // first-run prompt own them the same way.
  readonly property bool settingsHasFocus: root.settingsOpen && (
    (locationPicker && locationPicker.fieldFocused)
    || (settingsViewField && (settingsViewField.activeFocus || settingsViewField.popupOpen))
    || (settingsZoomField && settingsZoomField.activeFocus))

  function toggleSettings() {
    if (root.editingLocation) root.cancelEditingLocation()
    settingsOpen = !settingsOpen
    // A re-opened page starts at the top, not wherever it was left by a
    // tall screen that needed scrolling.
    if (settingsOpen) Qt.callLater(function() { settingsPage.contentY = 0 })
  }

  onSettingsOpenChanged: if (!settingsOpen) Qt.callLater(function() { keyCatcher.forceActiveFocus() })

  // ---------------------------------------------------------------------------
  // First-run location prompt
  // ---------------------------------------------------------------------------
  //
  // The first time the panel is opened with no location at all, a question
  // box asks for the city before the map does anything else. It shares the
  // geocoder and the suggestion list with the settings picker, and its
  // answer lands in the same weather.json through the same long-running
  // omarchy-weather-location call. `locationPrompted` is set whether the
  // answer was a city or a skip, so a fresh install is asked exactly once.

  property bool locationPromptOpen: false
  property string locationPromptQuery: ""

  function openLocationPrompt() {
    if (root.hasLocation) return
    locationPromptQuery = ""
    locationSuggestions = []
    suggestionIndex = 0
    locationPromptOpen = true
    Qt.callLater(function() { locationPromptField.forceActiveFocus() })
  }

  // Close the prompt for good: the question is asked exactly once, whether it
  // was answered or skipped, so every way out of it marks it asked and hands
  // focus back to the keyboard catcher.
  function closeLocationPrompt() {
    locationPromptOpen = false
    persistSetting("locationPrompted", true)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Skipped, not answered.
  function dismissLocationPrompt() {
    closeLocationPrompt()
  }

  // Chosen or free-typed. Mirrors commitLocation but for the prompt's own
  // field, and closes the box either way.
  function commitLocationPrompt() {
    var choice = RadarModel.locationCommit(locationPromptQuery, locationSuggestions, suggestionIndex)
    if (choice.name) persistLocation(choice.name, choice.latitude, choice.longitude)
    else if (locationPromptQuery.trim() !== "") clearLocation()
    closeLocationPrompt()
  }

  function promptPickSuggestion(suggestion) {
    if (!suggestion) return
    // Save the picked city with its coordinates straight away rather than
    // round-tripping through the field, which would have lost them.
    if (suggestion.name) persistLocation(suggestion.name, suggestion.latitude, suggestion.longitude)
    closeLocationPrompt()
  }

  // ---------------------------------------------------------------------------
  // Map state
  // ---------------------------------------------------------------------------

  readonly property bool hasLocation: service ? service.hasLocation === true : false
  // Held rather than bound, so an absent coordinate leaves them alone instead
  // of becoming a real one. A binding must yield a number — there is no way
  // to say "unchanged" — and any binding over the gap while `hasLocation`
  // catches up would place home at 0,0, off the coast of west Africa.
  property real homeLatitude: 0
  property real homeLongitude: 0
  // Deliberately not gated on `hasLocation`: that flag is derived from the
  // same object and settles a moment later, so requiring it here would
  // discard the one call that carries the coordinates. The parse below is
  // the only test that matters.
  function updateHome() {
    if (!service || !service.location) return
    var la = parseFloat(service.location.latitude)
    var lo = parseFloat(service.location.longitude)
    if (!isFinite(la) || !isFinite(lo)) return

    homeLatitude = la
    homeLongitude = lo

    // Recentre here rather than from a change handler on each coordinate.
    // Such a handler fires between the two writes, on the new latitude
    // beside the old longitude — a point that never existed, which the map
    // would centre on and fetch a full round of tiles for before being
    // corrected.
    if (!panned) recenter()
  }

  Connections {
    target: root.service
    function onLocationChanged() { root.updateHome() }
  }

  onServiceChanged: updateHome()
  readonly property string locationName: service ? service.locationName : ""
  readonly property string locationState: service ? service.locationState : "unset"

  property real viewLatitude: 0
  property real viewLongitude: 0
  property int zoom: Settings.defaultZoom(settings)

  // The map's own height, declared once because the limit on how far north
  // or south the view may sit is a question about the viewport rather than
  // about the centre: half a panel of world has to stay on each side of it.
  readonly property real mapHeight: Style.space(320)

  // Reapplied on zoom as well as on panning. Zooming out makes the same
  // panel cover more of the globe, so a centre that was legal deep in stops
  // being legal — without this, zooming out near a pole puts the world's
  // edge across the middle of the map.
  onZoomChanged: viewLatitude = TileMath.constrainLatitude(viewLatitude, zoom, mapHeight)

  // The radar layers stop requesting new detail here and get scaled up
  // instead, so the basemap can keep sharpening past the data's limit.
  readonly property int overlaySourceZoom: Math.min(zoom, RadarModel.MAX_RADAR_ZOOM)

  function recenter() {
    // Nothing to centre on before a location exists; recentring on the
    // placeholder would move the view to 0,0 rather than leave it alone.
    if (!hasLocation) return
    viewLatitude = TileMath.constrainLatitude(homeLatitude, zoom, mapHeight)
    viewLongitude = homeLongitude
  }

  onHasLocationChanged: updateHome()
  property bool panned: false

  // ---------------------------------------------------------------------------
  // CAMS categories and layers
  // ---------------------------------------------------------------------------
  //
  // The chips decide which overlay the timeline drives: "Radar" animates the
  // last two hours, a CAMS category animates its forecast steps. The overlays
  // themselves stack — selecting a CAMS layer draws it over the radar, and
  // switching back to Radar leaves it in place, frozen at its step, until it
  // is cleared with the ✕ in the picker.

  property string activeCategory: "radar"
  readonly property bool radarMode: activeCategory === "radar"

  readonly property string camsRegion: service ? service.camsRegion : "europe"
  readonly property var camsCategories: CamsModel.categoriesFor(service ? service.camsCaps : null, camsRegion)
  readonly property var chipCategories: ["radar"].concat(camsCategories)

  readonly property var camsLayers: radarMode
    ? [] : CamsModel.layersForCategory(service ? service.camsCaps : null, activeCategory, camsRegion)

  // One selection per category, so switching chips does not forget which
  // layer each one was showing.
  property var selectedLayerNames: ({})

  function setSelectedLayer(category, name) {
    var next = {}
    for (var key in selectedLayerNames) next[key] = selectedLayerNames[key]
    next[category] = name
    selectedLayerNames = next
  }

  function selectedLayerFor(category) {
    var name = selectedLayerNames[category]
    return name ? CamsModel.findLayer(service ? service.camsCaps : null, name) : null
  }

  readonly property var activeLayer: radarMode ? null : selectedLayerFor(activeCategory)

  function chooseCategory(id) {
    activeCategory = id
    // Written on every switch, whatever the default-view setting is, so that
    // "Last used" is accurate from the first chip the user ever touches — and
    // stays a record of the journey for anyone who switches the setting later.
    persistSetting("lastView", id)
    // A category visited for the first time opens on its first layer —
    // air-quality's is PM2.5, the one the bar tracks — rather than on a
    // picker with nothing chosen.
    if (id !== "radar" && !selectedLayerNames[id]) {
      var layers = CamsModel.layersForCategory(service ? service.camsCaps : null, id, camsRegion)
      if (layers.length > 0) setSelectedLayer(id, layers[0].name)
    }
  }

  // What the panel shows each time it opens: the widget's default-view
  // setting, resolved against the region. Allergens is Europe-only pollen, so
  // a default of it elsewhere reads as air quality — the same fallback
  // switching to that chip by hand gets. "Last used" reads the chip persisted
  // on every switch, falling back to radar before the first one.
  function applyDefaultView() {
    var id = Settings.viewIdFor(defaultView)
    if (id === "last") id = String(settings.lastView || "radar")
    if (id === "allergens" && camsRegion !== "europe") id = "air-quality"
    if (activeCategory === id) return
    chooseCategory(id)
  }

  // Air quality is the plugin's reason to exist, so as soon as the caps
  // arrive its first layer is selected — the overlay is on before the first
  // click. Clearing it from the picker is one ✕ away.
  Connections {
    target: root.service
    function onCamsCapsChanged() { root.autoSelectAirQuality() }
  }

  function autoSelectAirQuality() {
    if (!service || !service.camsCaps) return
    if (selectedLayerNames["air-quality"]) return
    var layers = CamsModel.layersForCategory(service.camsCaps, "air-quality", camsRegion)
    if (layers.length > 0) setSelectedLayer("air-quality", layers[0].name)
  }

  // What the map is actually drawing. The chips are exclusive: whichever
  // menu is active, only its overlay is on the map — radar frames come off
  // when a CAMS category is chosen, and the air layer comes off when the
  // Radar chip comes back. Both are held separately from the selection, so
  // switching chips never forget which layer each side had.
  property string shownAirLayerName: ""
  property string shownAirStepTime: ""

  // Whether the air overlay is what the map is drawing, and the legend ends
  // for its category when it is.
  readonly property bool airShown: shownAirLayerName !== ""
  readonly property var airLegendEnds: airShown ? CamsModel.legendEnds(activeCategory) : null

  function syncAirOverlay() {
    // Not the air menu, no air overlay — the selection stays for the return.
    if (radarMode) {
      shownAirLayerName = ""
      shownAirStepTime = ""
      return
    }
    var layer = activeLayer
    if (!layer) return
    shownAirLayerName = layer.name
    var steps = CamsModel.layerSteps(layer)
    if (steps.length === 0) return
    var index = Frames.clampIndex(camsFrames, camsFrameIndex)
    // The layer and its frame model update in separate binding turns. While
    // the new list is still empty clampIndex answers -1; assigning
    // steps[-1] would throw before the later turn can supply the first step.
    if (index < 0) return
    shownAirStepTime = steps[Math.min(index, steps.length - 1)]
  }

  function clearAirOverlay() {
    shownAirLayerName = ""
    shownAirStepTime = ""
    // The selection goes with it, so re-entering the category re-selects its
    // default rather than silently resurrecting what was cleared.
    if (!radarMode) setSelectedLayer(activeCategory, undefined)
  }

  // The radar half of the same exclusivity. The timeline position
  // (`frameIndex`, `shownTime`, `followingLatest`) is untouched either way —
  // only what the map draws comes and goes — so returning to the Radar chip
  // resumes exactly where the loop was, at whatever frame the list now holds.
  function syncRadarOverlay() {
    if (radarMode) {
      if (frames.length > 0) showFrame(Frames.clampIndex(frames, frameIndex))
      return
    }
    frameA = -1
    frameB = -1
    swapPending = false
    swapWatchdog.stop()
  }

  // A chip change must be acted on after `radarMode` and `activeLayer` — both
  // bindings over `activeCategory` — have settled. QML runs this handler while
  // those still hold the previous chip, so reading them here would take the
  // wrong branch on the way back to Radar: it would clear the radar frames
  // instead of staging one, and leave the air overlay up. Deferring to the end
  // of the turn reads the settled values and restages the radar frame.
  onActiveCategoryChanged: Qt.callLater(function() {
    syncAirOverlay()
    syncRadarOverlay()
  })

  // ---------------------------------------------------------------------------
  // CAMS forecast steps
  // ---------------------------------------------------------------------------

  readonly property var activeStepTimes: activeLayer ? CamsModel.layerSteps(activeLayer) : []
  readonly property var camsFrames: activeStepTimes.map(function(iso) {
    return { time: Date.parse(iso) / 1000, iso: iso }
  })

  // The forecast has no replay: the overlay always serves the step nearest
  // now, and re-centres on it whenever the layer or its list changes.
  property int camsFrameIndex: 0

  onCamsFramesChanged: {
    if (camsFrames.length === 0) return
    var next = CamsModel.nearestTimeIndex(activeStepTimes)
    if (next !== camsFrameIndex) camsFrameIndex = next
    syncAirOverlay()
  }

  onCamsFrameIndexChanged: syncAirOverlay()

  // A newly chosen layer opens on ~now, not on the analysis time.
  onActiveLayerChanged: {
    if (!activeLayer) return
    camsFrameIndex = CamsModel.nearestTimeIndex(CamsModel.layerSteps(activeLayer))
    syncAirOverlay()
  }

  // ---------------------------------------------------------------------------
  // Timeline
  // ---------------------------------------------------------------------------
  //
  // The scrubber/play loop belongs to the radar: past frames get replayed, a
  // CAMS forecast is a single latest step with no transport of its own. The
  // shared properties below keep the kit's Timeline generic over either model
  // while only the radar ever feeds it.

  readonly property var timelineFrames: radarMode ? frames : camsFrames
  readonly property int timelineIndex: radarMode ? frameIndex : camsFrameIndex
  readonly property var timelineFrame: radarMode ? currentFrame
    : (camsFrames.length ? camsFrames[Frames.clampIndex(camsFrames, camsFrameIndex)] : null)
  readonly property string timelineLabel: !timelineFrame ? "--:--"
    : (radarMode ? RadarModel.formatFrameTime(timelineFrame.time)
                 : CamsModel.formatStepTime(timelineFrame.iso))
  // How stale the shown radar picture is, under the clock. Empty on the
  // newest frame — "ago" is only an answer while the picture is in the past —
  // and never set for CAMS, whose steps are forecasts rather than history.
  readonly property string timelineAgo: radarMode && timelineFrame && !timelineAtLatest
    ? RadarModel.formatFrameAgo(timelineFrame.time, Date.now()) : ""
  readonly property bool timelineAtLatest: radarMode
    ? isLatestFrame : Frames.isLatest(camsFrames, camsFrameIndex)

  function setTimelineIndex(index) {
    // Only the radar loop replays; a CAMS forecast always shows latest.
    if (!radarMode) return
    playing = false
    frameIndex = index
  }

  // ---------------------------------------------------------------------------
  // Location editing
  // ---------------------------------------------------------------------------
  //
  // Deliberately the same picker as the stock weather widget: same geocoding
  // endpoint, same suggestion rows, same omarchy-weather-location call.
  // There is one location on this machine, and it is the weather widget's
  // file. Changing the city here moves the stock weather widget too, and
  // vice versa — both watch the file.

  property bool editingLocation: false
  property bool savingLocation: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodePendingQuery: ""
  property string geocodeActiveQuery: ""

  // Which picker mode the edit session is in — the city search or exact GPS
  // coordinates — and why a coordinate commit was refused. The coordinate
  // fields themselves are read and seeded through `locationPicker` aliases,
  // like the search field, so the panel never binds to live text.
  property string locationEditMode: "city"
  property string coordinateError: ""

  function startEditingLocation() {
    if (editingLocation) return
    editingLocation = true
    // The picker lives on the settings page now, so reaching it opens that
    // page too — clicking the header's location is a shortcut to the edit.
    settingsOpen = true
    locationSuggestions = []
    suggestionIndex = 0
    locationPicker.query = root.locationName
    // The exact-GPS fields are seeded with what is actually stored, whether
    // it came from a geocoded city or from a typed pair, so switching modes
    // shows the current point rather than a blank form.
    root.locationEditMode = "city"
    root.coordinateError = ""
    locationPicker.coordinateName = root.locationName
    locationPicker.coordinateLatitude = root.hasLocation ? String(root.service.location.latitude) : ""
    locationPicker.coordinateLongitude = root.hasLocation ? String(root.service.location.longitude) : ""
    Qt.callLater(function() { locationPicker.focusQuery() })
  }

  function cancelEditingLocation() {
    editingLocation = false
    savingLocation = false
    locationSuggestions = []
    suggestionIndex = 0
    geocodePendingQuery = ""
    coordinateError = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // The same coordinate pair reaches the shared weather.json either way: the
  // geocoder resolves a name to a point, a typed pair names nothing itself,
  // so the name field and the two numbers are what get saved.
  function switchLocationEditMode(mode) {
    root.locationEditMode = mode === "coordinates" ? "coordinates" : "city"
    root.coordinateError = ""
    Qt.callLater(function() {
      if (mode === "coordinates") locationPicker.focusCoordinates()
      else locationPicker.focusQuery()
    })
  }

  function commitCoordinates() {
    if (root.savingLocation) return
    var parsed = RadarModel.parseCoordinates(locationPicker.coordinateLatitude,
      locationPicker.coordinateLongitude)
    if (!parsed) {
      root.coordinateError = "Enter a plain latitude (−90 to 90) and longitude (−360 to 360; past ±180 wraps onto the globe)"
      return
    }
    var name = locationPicker.coordinateName.trim()
    if (name === "") {
      root.coordinateError = "Name the location — that is what the header shows"
      return
    }
    root.coordinateError = ""
    root.savingLocation = true
    root.persistLocation(name, parsed.latitude, parsed.longitude)
  }

  function commitLocation() {
    var choice = RadarModel.locationCommit(locationPicker.query, locationSuggestions, suggestionIndex)
    if (!choice.name) {
      clearLocation()
      return
    }
    savingLocation = true
    persistLocation(choice.name, choice.latitude, choice.longitude)
  }

  function pickSuggestion(suggestion) {
    if (!suggestion) return
    savingLocation = true
    persistLocation(suggestion.name, suggestion.latitude, suggestion.longitude)
  }

  function clearLocation() {
    savingLocation = true
    persistLocation("", null, null)
  }

  // What the last save asked for, so a save that changes nothing can be told
  // apart from one that does.
  property real pendingLatitude: NaN
  property real pendingLongitude: NaN

  function persistLocation(name, latitude, longitude) {
    pendingLatitude = parseFloat(latitude)
    pendingLongitude = parseFloat(longitude)

    if (name && latitude !== null && longitude !== null)
      locationSaveProc.launch(["omarchy-weather-location", "--set", name, latitude + "," + longitude])
    else if (name)
      locationSaveProc.launch(["omarchy-weather-location", "--set", name])
    else
      locationSaveProc.launch(["omarchy-weather-location", "--clear"])
  }

  // Debounced so typing a city name is one request per pause, not one per
  // keystroke. Only one curl is in flight at a time; a query that moved on
  // while a fetch was running is issued as soon as that one returns.
  // Which field asked: the first-run prompt has its own field, the settings
  // picker has the picker's.
  function activeEditQuery() {
    if (root.locationPromptOpen) return root.locationPromptQuery
    return locationPicker.query
  }

  function requestGeocode() {
    var query = root.activeEditQuery().trim()
    if (query.length < 2) {
      locationSuggestions = []
      return
    }
    geocodePendingQuery = query
    if (!geocodeProc.running) startGeocode()
  }

  function startGeocode() {
    geocodeActiveQuery = geocodePendingQuery
    geocodeProc.launch(RadarModel.geocodingCommand(geocodeActiveQuery, 5))
  }

  Timer {
    id: geocodeDebounce
    interval: 220
    onTriggered: root.requestGeocode()
  }

  BoundedProcess {
    id: geocodeProc
    onResponded: function(exitCode, text) { root.applyGeocodeResponse(exitCode, text) }
  }

  function applyGeocodeResponse(exitCode, text) {
    // A failed search leaves no suggestions rather than stale ones: a list
    // from the previous query, under the letters just typed, is a wrong
    // answer presented as a current one. The first-run prompt counts as a
    // live edit too — it shares the same suggestion list.
    var liveEdit = root.editingLocation || root.locationPromptOpen
    root.locationSuggestions = (exitCode === 0 && liveEdit)
      ? RadarModel.parseGeocodingResults(text) : []
    root.suggestionIndex = 0

    // Only when there is still a search to run. cancelEditingLocation()
    // clears the pending query, and a successful save routes through it too
    // — so a request in flight when the user presses Escape would come back,
    // find pending and active different, and go out again for the empty
    // string: a real call to the geocoder for nothing, after the field is
    // closed.
    if (!liveEdit || root.geocodePendingQuery === "") return
    if (root.geocodePendingQuery !== root.geocodeActiveQuery) Qt.callLater(root.startGeocode)
  }

  BoundedProcess {
    id: locationSaveProc
    onResponded: function(exitCode, text) { root.applyLocationSave(exitCode) }
  }

  function applyLocationSave(exitCode) {
    root.savingLocation = false
    if (exitCode !== 0) return

    // Clear `panned` before anything can deliver a location, so the order of
    // what follows cannot decide whether the map recentres.
    root.panned = false

    // Recentre now only when what was saved is what home already holds —
    // re-choosing the stored city, where identical coordinates mean no
    // property changes and so nothing else would fire. Doing it
    // unconditionally would snap the map to the previous city first on a
    // move, and onto the city just removed on a clear.
    if (isFinite(root.pendingLatitude)
        && root.pendingLatitude === root.homeLatitude
        && root.pendingLongitude === root.homeLongitude) root.recenter()

    // Then ask the service to re-read rather than waiting for its file
    // watch. The first location ever written lands in a directory that did
    // not exist when that watch was set up, so nothing would announce it.
    if (root.service && root.service.reloadLocation) root.service.reloadLocation()

    root.cancelEditingLocation()
  }

  // ---------------------------------------------------------------------------
  // Frames
  // ---------------------------------------------------------------------------

  readonly property var frames: service ? service.frames : []
  property int frameIndex: 0
  property bool playing: false

  // What the user is looking at, expressed so that it survives the list
  // being replaced: the moment on screen, and whether they chose to follow
  // the newest frame. Both are recorded while the list that produced them is
  // still in hand — an index into the old list means nothing in the new one.
  property real shownTime: 0
  property bool followingLatest: true

  // Bumped whenever the list is replaced. At an unchanged index a new
  // manifest is still a different frame, and without this the tile layers
  // keep the tiles they already have.
  property int frameEpoch: 0

  readonly property var currentFrame: {
    var index = Frames.clampIndex(frames, frameIndex)
    return index < 0 ? null : frames[index]
  }

  readonly property bool isLatestFrame: Frames.isLatest(frames, frameIndex)

  // Jump to the newest frame in hand, and follow it from here. What "newest"
  // means is decided again each time the list is replaced, so this holds even
  // when the list on screen is hours old and the real one has not arrived.
  function showLatestFrame() {
    followingLatest = true
    var latest = frames.length - 1
    if (latest >= 0 && frameIndex !== latest) frameIndex = latest
    else recordShownFrame()
  }

  function recordShownFrame() {
    var frame = currentFrame
    shownTime = frame ? frame.time : 0
    followingLatest = Frames.isLatest(frames, frameIndex)
  }

  // A new manifest arrives every ten minutes, and the panel is opened against
  // lists it has never seen. Someone parked on the newest frame wants the
  // newest frame whatever the new list looks like; someone who scrubbed back
  // to a time wants that time, at whatever index it now sits.
  onFramesChanged: {
    if (frames.length === 0) return
    frameEpoch++

    var next = Frames.reselect(frames, shownTime, followingLatest)
    if (next !== frameIndex) {
      frameIndex = next
    } else {
      // The same position in a different list is a different frame, so the
      // layers are told even though the index did not move.
      showFrame(frameIndex)
      recordShownFrame()
    }

    // First frames after a manifest: only the radar chip populates the
    // layers. While a CAMS category owns the map the position is kept in
    // `frameIndex` alone, ready for the return.
    if (radarMode && frameA < 0) { frameA = frameIndex; frontIsA = true }
  }

  // Crossfade state. Two tile layers alternate: the incoming frame is staged
  // into whichever is currently behind, and the two swap opacity only once
  // that layer has every tile it asks for.
  //
  // Swapping the moment the frame is assigned reads as a flash: the incoming
  // tiles have not decoded, so the 380 ms fade runs against a blank layer —
  // the current frame fades out, the ground shows through, and the new frame
  // pops in afterwards. Gating the swap on readiness turns the same animation
  // into a dissolve between two fully drawn frames, and paces the loop to the
  // network: a step takes as long as its tiles do, not less.
  property int frameA: -1
  property int frameB: -1
  property bool frontIsA: true
  property bool swapPending: false

  onFrameIndexChanged: showFrame(frameIndex)

  function showFrame(index) {
    if (index < 0 || frames.length === 0) return
    // Another chip owns the map: the radar keeps its timeline position but
    // draws nothing. Choosing the Radar chip again stages this frame.
    if (!radarMode) return
    if (frontIsA) frameB = index
    else frameA = index
    swapPending = true
    // A tile the network never answers must not park the loop forever. Two
    // seconds in, the swap goes ahead regardless: on a dead connection that
    // degrades to the old flash rather than to a frozen map.
    swapWatchdog.restart()
    commitIfReady()
  }

  function commitIfReady() {
    if (!swapPending || !map.backReady) return
    finishSwap()
  }

  function commitForced() {
    if (!swapPending) return
    finishSwap()
  }

  function finishSwap() {
    swapPending = false
    frontIsA = !frontIsA
    // The caption moves with the picture, not with the request.
    recordShownFrame()
    // A share is waiting on this frame to be drawn, and "drawn" is later than
    // "all the tiles are here" by the length of the crossfade. So the grab is
    // queued behind the fade rather than fired from inside it, which is what
    // photographs a half-transparent layer and bakes the dissolve into every
    // frame of a loop.
    if (sharing) shareSettle.restart()
    // While playing, the layer now behind is idle: hand it the next frame so
    // its tiles decode during the hold, and the next swap is a crossfade
    // between two loaded frames instead of a wait. A cache hit answers
    // synchronously, so on the second pass through the loop the swap is
    // immediate.
    if (playing && frames.length > 1) {
      var next = Frames.nextIndex(frames, frameIndex)
      if (frontIsA) frameB = next
      else frameA = next
    }
  }

  Timer {
    id: swapWatchdog
    interval: 2000
    onTriggered: root.commitForced()
  }

  function tileUrlForFrame(index, z, x, y) {
    if (!root.service || !root.service.tileHost) return ""
    if (index < 0 || index >= root.frames.length) return ""
    var url = RadarModel.tileUrl(root.service.tileHost, root.frames[index].path, 256,
      z, x, y, root.colorSchemeId, root.smoothTiles, root.showSnow)
    // A retry needs a fresh cache key: Qt's loader caches by URL and will
    // hand back the still-stuck request forever otherwise.
    if (map.tileRetry > 0) return url + "?r=" + map.tileRetry
    return url
  }

  Timer {
    id: playbackTimer
    // Slow enough to read the motion rather than watch a strobe, with a
    // longer hold on the newest frame — and slow enough that the tile decode
    // of the next frame usually finishes before the clock asks for it. When
    // it does not, the tick below waits: advancing past a frame still loading
    // would abandon it and start another wait, and the loop would stutter
    // rather than breathe.
    interval: isLatestFrame ? 2000 : 850
    repeat: true
    running: root.playing && root.opened && root.radarMode && frames.length > 1
    onTriggered: {
      if (root.swapPending) return
      root.frameIndex = Frames.nextIndex(frames, root.frameIndex)
    }
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  function open() {
    root.controller.show()
    root.onOpened()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.playing = false
    root.locationPromptOpen = false
    if (root.editingLocation) root.cancelEditingLocation()
    root.settingsOpen = false
    if (root.manifestHeld) {
      if (root.service && root.service.releaseManifest) root.service.releaseManifest()
      root.manifestHeld = false
    }
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  property bool manifestHeld: false

  // A bar surface is rebuilt per monitor, so a panel can be destroyed while
  // it still holds the manifest — unplugging a screen with the map open.
  // Without this the refcount never comes back down and the service keeps
  // fetching frames for a panel nobody has.
  Component.onDestruction: {
    if (manifestHeld && root.service && root.service.releaseManifest) root.service.releaseManifest()

    // A share in progress must not outlive the panel. The grab that may be in
    // flight is Qt's to finish, but the frames already on disk are this
    // plugin's, and the run directory is named for the shell process that made
    // it — so a shell reload or a plugin upgrade mid-share would leave it
    // behind for good.
    if (root.sharing) {
      shareFrameTimer.stop()
      shareSettle.stop()
      shareFence.stop()
      shareProc.cancelRequested = true
      clipboardProc.cancelRequested = true
      if (shareRunDir !== "")
        shareProc.launch(root.shareHelper.concat(["abort", shareRunDir]))
    }
  }

  function onOpened() {
    // Opening is a question about now, so the view and the clock both start
    // there. While the panel is open, Frames.reselect keeps whoever is
    // studying a particular time on that time as the list moves under them.
    panned = false
    if (hasLocation) recenter()
    showLatestFrame()
    applyDefaultView()
    // A fresh open starts from clean tile URLs. A retry suffix from an
    // earlier stall would key straight into the still-stuck cache entry.
    map.tileRetry = 0

    // A brand-new install with no location anywhere is asked for its city
    // before anything else. Asked once, and only when there is genuinely
    // nothing to look at.
    if (!hasLocation && !Settings.locationPrompted(settings))
      Qt.callLater(root.openLocationPrompt)
    // The CAMS overlay opens on ~now too, wherever it was left.
    if (activeLayer) {
      camsFrameIndex = CamsModel.nearestTimeIndex(CamsModel.layerSteps(activeLayer))
      syncAirOverlay()
    }
    if (root.service && !manifestHeld) {
      root.service.acquireManifest()
      manifestHeld = true
    }

    // Opening the map is a request for current information, and the frames,
    // the forecast and the air reading are all things that can have gone
    // stale or started failing while it was closed.
    if (root.service && root.service.refreshIfStale) root.service.refreshIfStale()
    if (root.service && root.service.refreshAqIfStale) root.service.refreshAqIfStale()

    // Ask the tile layers to fetch again. Qt never retries an Image that
    // failed, and the frame list can be current while the tiles under it
    // were requested during an outage. Anything already held is served from
    // the cache, so this costs a request only for what is actually missing.
    frameEpoch++
    // The canvas can only read pixels while it is on screen, so opening is
    // the moment to ask.
    Qt.callLater(function() { coverageProbe.probe() })
  }

  function setCenterHoverRevealSuppressed(value) {
    if (!root.bar) return
    // PluginBarApi exposes centerHoverRevealSuppressed as readonly. In QML,
    // setCenterHoverRevealSuppressed() is that property's setter and throws,
    // which aborts close() before the panel actually hides.
    if (typeof root.bar._setCenterHoverRevealSuppressed === "function") {
      root.bar._setCenterHoverRevealSuppressed(value)
      return
    }
    try {
      root.bar.centerHoverRevealSuppressed = value
    } catch (e) {}
  }

  IpcHandler {
    target: root.ipcTarget

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
  }

  // ---------------------------------------------------------------------------
  // Map wiring
  // ---------------------------------------------------------------------------

  // The ground is drawn from geometry that ships with the plugin, decoded
  // once by the service. See ui/BasemapLayer.qml for why its colours follow
  // the theme while the radar's do not.
  readonly property var basemap: service ? service.basemap : null

  // Credit for everything drawn on the map, in one place so it cannot fall
  // out of step with where the data actually comes from. Per view, because a
  // shared air-quality image is a picture of ECMWF's data and an image that
  // does not say so is unattributed however the plugin behaves on screen.
  readonly property string attribution: Share.attribution(activeCategory)

  function tileUrlA(z, x, y) { return root.tileUrlForFrame(root.frameA, z, x, y) }
  function tileUrlB(z, x, y) { return root.tileUrlForFrame(root.frameB, z, x, y) }

  // Large parts of the world have no ground radar at all, and there the map
  // is simply empty — which is indistinguishable from "no rain today" and
  // reads as a broken plugin. RainViewer publishes a coverage mask that is
  // transparent where a radar reaches and opaque black where none does, so
  // the question is answerable: fetch the mask centred on the user and read
  // the middle pixel, which is their location by construction.
  //
  // The probe is mounted in the panel's tree rather than in the service
  // because reading pixels needs a scene to render into, and a headless
  // singleton has none. See ui/CoverageProbe.qml.
  readonly property string coverageProbeUrl: {
    if (!service || !service.tileHost || !hasLocation) return ""
    if (service.coverageChecked) return ""
    return RadarModel.coverageTileUrl(service.tileHost, 256, RadarModel.MAX_RADAR_ZOOM,
      homeLatitude, homeLongitude)
  }

  readonly property bool coverageMissing: service ? (service.coverageChecked && !service.hasCoverage) : false

  // Whether any work is in flight right now: the service's polls, the map's
  // tiles and CAMS overlay, or a location being saved. The initial empty map
  // counts too, but only until fetching it is known to have failed, so an
  // outage does not blink "Fetching" forever.
  //
  // Deliberately not what the header renders. Switching a chip back to Radar
  // re-reads tiles from Qt's pixmap cache, which still counts here while the
  // images decode — so the raw signal flickers for work that cost no network.
  readonly property bool fetchingBusy: {
    if (root.savingLocation) return true
    if (root.service && root.service.fetching) return true
    if (map.fetching) return true
    if (root.frames.length === 0 && !(root.service && root.service.frameFailures > 0)) return true
    return false
  }

  // What the header shows: "Fetching" only once the work has outlived a cache
  // read. A cached decode settles well inside this window, so chip switches do
  // not blink the header; a request that really has to travel still does.
  readonly property int fetchingSettleMs: 500
  property bool fetching: false

  Timer {
    id: fetchingSettle
    interval: root.fetchingSettleMs
    onTriggered: root.fetching = true
  }

  onFetchingBusyChanged: {
    if (root.fetchingBusy) {
      if (!root.fetching) fetchingSettle.restart()
    } else {
      fetchingSettle.stop()
      root.fetching = false
    }
  }

  Component.onCompleted: if (root.fetchingBusy) fetchingSettle.start()

  // ---------------------------------------------------------------------------
  // Sharing
  //
  // A share is a grab of the map item, and a grab is whatever is on screen —
  // so the loop is the radar's own transport, driven one frame at a time
  // instead of by the playback timer. Nothing here re-renders the map or
  // re-requests a tile: it steps the frame the panel already knows how to
  // stage, waits for that frame to be fully drawn, and grabs it.
  //
  // Which means the state it borrows has to come back afterwards. The frame
  // index, the followed time and the transport all move during a share, and a
  // share that left the panel on a different frame than the one the user was
  // looking at would be the worst bug in this file.
  // ---------------------------------------------------------------------------

  // "" when nothing is being shared, otherwise "image" or "gif". Not a bool:
  // the mode is also the extension, and the two must not be able to disagree.
  property string shareMode: ""
  readonly property bool sharing: shareMode !== ""
  property int shareDone: 0
  property int shareTotal: 1

  // The frames of the loop, as indexes into `frames`, and where the helper
  // said their pixels go. Both are filled in one step, from one answer.
  property var shareIndexes: []
  property var sharePaths: []
  property string shareRunDir: ""
  property int shareCursor: 0

  // How long the frame list was when the share started. See captureNextFrame().
  property int shareFramesToken: -1

  // What the file is called, decided once at the start so a loop lands in one
  // file rather than one file per minute of the clock.
  property string shareStem: ""

  // Borrowed from the panel for the length of the share, and handed back by
  // endShare() on every path out — the successful one and the failed ones.
  property int shareSavedIndex: -1
  property bool shareSavedPlaying: false
  property bool shareSavedFollowing: true

  // The capture's own path to the helper. Absolute interpreter, absolute
  // helper, -I so no PYTHONPATH rides in, -S because nothing outside the
  // standard library is used and the site directory is another process's
  // decision. Every argument is its own array element, so nothing here is
  // ever parsed as a shell.
  readonly property var shareHelper: ["/usr/bin/python3", "-I", "-S", pluginFile("share.py")]

  // The window between "this frame is on screen" and "this frame is what a
  // grab would photograph". The tile swap is already fenced by swapWatchdog;
  // the crossfade that finishes it is 380 ms, so a grab taken the moment
  // `backReady` goes true photographs a half-transparent layer and bakes the
  // dissolve into every frame of a loop.
  readonly property int shareSettleMs: 450

  function requestShare() {
    if (root.sharing || root.settingsOpen) return
    // Only the radar has a transport to replay, so only the radar has a loop
    // to make. Every other view offers the still and nothing else, which is
    // the answer the timeline already gives: a CAMS forecast is never
    // scrubbed, so there is no sequence of it to animate.
    if (!root.radarMode) {
      root.startShare("image")
      return
    }
    shareChooser.opened = true
  }

  // Take whichever option the chooser has selected, whether it was arrived at
  // with the keyboard or with the mouse.
  //
  // One function for all three ways in — the right button, the left button and
  // Return — because three copies of an if/else is three chances to map the
  // left button to "close the dialog", which is precisely what happened: the
  // image was the left button, and choosing it did nothing at all.
  function chooseShareFormat() {
    if (shareChooser.selectedIndex === 0) root.startShare("image")
    else root.startShare("gif")
  }

  function startShare(mode) {
    if (root.sharing) return
    shareChooser.opened = false

    var wanted = Share.windowFor(mode, frames.length, frameIndex)
    if (mode === "gif" && wanted.length < 2) {
      // A loop of one is a still with extra steps, and a worse answer than the
      // PNG would have been.
      root.endShare("Nothing to animate — one radar frame is all there is", false)
      return
    }
    if (wanted.length === 0) {
      root.endShare("There is no frame to share yet", false)
      return
    }

    root.shareMode = mode
    root.shareTotal = wanted.length
    root.shareIndexes = wanted
    root.shareCursor = 0
    root.sharePaths = []
    root.shareRunDir = ""
    root.shareStem = Share.fileName(Share.kindFor(activeCategory, activeLayer, ""), Date.now())

    root.shareSavedIndex = frameIndex
    root.shareSavedPlaying = playing
    root.shareSavedFollowing = followingLatest
    root.shareFramesToken = frames.length

    // setTimelineIndex() pauses the transport on every frame it stages, so
    // this is belt and braces — and it is also the pause that would apply to a
    // still, where the frame being shared is usually the one already on screen
    // and nothing is ever staged.
    playing = false

    root.sharePending = "begin"
    shareProc.launch(root.shareHelper.concat(["begin", String(wanted.length)]))
  }

  // Escape, the button in the hint row, and the failure paths all land here or
  // on endShare(). The run directory is removed by a separate call because
  // there is no `finish` on the way out of a cancel: the frames are already on
  // disk and nothing else is going to look at them.
  function endShare(headline, ok) {
    shareFrameTimer.stop()
    shareSettle.stop()
    shareFence.stop()
    // Read before it is cleared: the reason is only useful while there is
    // still a share to explain.
    var why = root.shareReason()
    // Whatever the helper is still doing, its answer is no longer wanted. A
    // cancel is answered after the share is already over, and treating that
    // answer as a result is how a cancelled share ends up reporting that the
    // helper said something unexpected.
    root.sharePending = ""

    root.shareMode = ""
    root.shareIndexes = []
    root.sharePaths = []
    root.shareRunDir = ""
    root.shareCursor = 0
    root.shareDone = 0

    // Assigning the index stages the frame through onFrameIndexChanged, so
    // this is the whole of putting the picture back.
    if (root.shareSavedIndex >= 0 && root.shareSavedIndex < frames.length)
      frameIndex = root.shareSavedIndex
    playing = root.shareSavedPlaying
    followingLatest = root.shareSavedFollowing

    root.shareWhy = ""
    if (headline !== "" && root.service) root.service.reportShare(headline, ok, why)
  }

  function captureNextFrame() {
    if (!root.sharing) return
    // A new manifest replaces the frame list every ten minutes, and the frames
    // a radar share is walking are indexes into the list it started with. Ten
    // seconds of sharing will not usually meet one, and the one time it does
    // the indexes name different frames than they did — so the share is
    // stopped rather than allowed to capture the wrong weather. Only a radar
    // share is walking indexes, and only a radar share can be caught by this.
    if (root.radarMode && frames.length !== root.shareFramesToken) {
      root.failShare("The radar frames changed — try sharing again")
      return
    }
    if (root.shareCursor >= root.sharePaths.length) {
      root.publishShare()
      return
    }

    root.shareDone = root.shareCursor + 1

    if (!root.radarMode) {
      // There is nothing to stage: the map is already showing the layer and
      // the forecast step this share means, so the grab is the whole of the
      // work. Staging a radar frame here would be a no-op — setTimelineIndex()
      // refuses a view that is not the radar — and the only thing left to
      // release the grab would be the eight-second fence, which would make
      // every air-quality share feel like it had hung.
      grabFrame()
      return
    }

    var index = root.shareIndexes[root.shareCursor]

    if (index === frameIndex) {
      // The frame is already on screen, and `setTimelineIndex` assigns
      // `frameIndex = index` — which fires no signal when the value is
      // unchanged, so `showFrame` never runs, the swap is never pending, and
      // `finishSwap` never releases a grab. The crossfade that is already
      // settling is the only wait this needs.
      //
      // A still is always this case, because a still is the frame the user is
      // looking at. A loop hits it whenever the window includes the frame the
      // panel was left on. Without this branch every still waited out the fence
      // — eight seconds of a map that is not moving, under a progress row that
      // says it is rendering.
      shareSettle.restart()
      return
    }

    setTimelineIndex(index)
    // The swap lands when the tiles are all here, and swapWatchdog forces it
    // two seconds later if they never are. Either way finishSwap() releases
    // the settle, and the settle releases the grab. The fence below is the
    // third thing that can release it, for a frame where neither of the other
    // two does — on a bad connection that degrades to a rough loop rather than
    // to a share that never finishes.
    shareFence.restart()
  }

  function grabFrame() {
    if (!root.sharing) return
    // The fence has done its job. Left running it would open a second grab of
    // the same item while the first was still queued, and two overlapping
    // grabs of one item each photograph the other's half-finished state.
    shareFence.stop()

    // The still is grabbed at twice the map's own size, because it is the one
    // meant to be posted. A loop is grabbed at 1x: twice the pixels across
    // eight frames is a file nobody waits for, and the map is small enough
    // that scaling it up would only show the basemap's own interpolation.
    var scale = root.shareMode === "gif" ? 1 : 2
    var target = Qt.size(Math.max(1, Math.round(map.width * scale)),
      Math.max(1, Math.round(map.height * scale)))
    var destination = root.sharePaths[root.shareCursor]
    var next = root.shareCursor + 1

    map.grabToImage(function(result) {
      if (!root.sharing) return
      if (!result.saveToFile(destination)) {
        root.failShare("Could not write the captured frame")
        return
      }
      root.shareCursor = next
      // On to the next frame — or, once they are all written, to the publish.
      // One step of this loop is the whole of the state machine: the timer
      // calls captureNextFrame(), which either stages the next frame or hands
      // the finished run to the helper.
      shareFrameTimer.restart()
    }, target)
  }

  // Every way out of a share that does not finish, with its frames cleaned up
  // behind it. Cancel, a frame that could not be written, a frame list that
  // moved underneath the share — they differ only in what the user is told,
  // and the bookkeeping that follows is the same every time.
  function failShare(headline) {
    shareChooser.opened = false
    shareFrameTimer.stop()
    shareSettle.stop()
    shareFence.stop()
    if (shareRunDir !== "") {
      root.sharePending = "abort"
      shareProc.launch(root.shareHelper.concat(["abort", shareRunDir]))
    }
    root.endShare(headline, false)
  }

  function publishShare() {
    if (shareRunDir === "") {
      root.failShare("The share never started")
      return
    }
    root.sharePending = "finish"
    shareProc.launch(root.shareHelper.concat(
      ["finish", shareRunDir, root.shareMode, root.shareStem]))
  }

  // The step from one captured frame to the next. It calls captureNextFrame()
  // rather than grabFrame(), because captureNextFrame() is what notices there
  // are no frames left — a timer that grabbed unconditionally would walk off
  // the end of the list and try to write a file that was never named.
  Timer {
    id: shareFrameTimer
    interval: 40
    onTriggered: root.captureNextFrame()
  }

  // The pause between a frame being on screen and it being safe to
  // photograph. Two callers, one wait: a swap that has just started
  // crossfading, and a frame that was already showing and never had to.
  Timer {
    id: shareSettle
    interval: root.shareSettleMs
    onTriggered: root.grabFrame()
  }

  // The last thing that can release a grab, for a frame whose tiles never
  // arrive and whose watchdog therefore never fires because the swap was never
  // pending. Long enough that it is not what happens on a good connection.
  Timer {
    id: shareFence
    interval: 8000
    onTriggered: root.grabFrame()
  }

  BoundedProcess {
    id: shareProc
    // The helper's reason for failing, which is otherwise thrown away.
    //
    // stderr on a Quickshell process that has not claimed it goes to the
    // shell's log, which is where a developer looks and not where a person
    // with a failed share looks. It arrives here instead, capped, and becomes
    // the body of the toast — so a refusal says what was refused rather than
    // only that it was. Bounded like the stdout, because it is a stream into
    // this process either way.
    //
    // The collector only accumulates. It must not decide anything, because
    // `onStreamFinished` fires before the exit code exists, so a refusal
    // decided there would read as one that completed. The text is read in
    // onResponded, where the code is known — the arrangement BoundedProcess
    // itself uses for stdout.
    stderr: StdioCollector {
      id: shareErrors
      waitForEnd: true
    }
    onResponded: function(exitCode, text) {
      // Read only. `text` is a read-only property backed by the collector's
      // own buffer, and assigning to it throws — which aborts this handler
      // before applyShareResponse() runs, so the run directory gets created and
      // its name never arrives, and the share waits for a cancel that cannot
      // clean up after it. Nothing needs clearing either: the collector belongs
      // to this process, and launching it again starts a new one.
      //
      // The first line, and only the first: a helper that printed a stack has
      // its first sentence in the toast and the rest dropped.
      root.shareWhy = shareErrors.text.split("\n")[0]
      root.applyShareResponse(exitCode, text)
    }
  }

  // What the helper said, when it said something. Shown once, in the toast,
  // and dropped with the share.
  property string shareWhy: ""

  // A helper sentence in a notification body, which is a sink the plugin
  // cannot render as plain text. Stripped of the characters that start markup,
  // of the controls, and of the bidi overrides that can reorder what the user
  // reads. The rest of it is this plugin's own wording about the user's own
  // files, so there is nothing else to remove.
  function shareReason() {
    if (root.shareWhy === "") return "The share helper refused without saying why."
    return Share.plain(root.shareWhy)
  }

  // stdout crosses a process boundary and is collected into the shell process,
  // so its ceiling is checked on this side too. The helper applies the same
  // 4 KiB bound before it prints; this is the same bound one layer over, where
  // the bytes already exist.
  readonly property int shareAnswerMax: 4096

  // What the helper is currently being asked, so an answer is only ever read
  // against the question that asked for it. Dispatching on whether a run
  // directory happens to be set looks like it works and does not: the answer to
  // `finish` arrives while the run directory is still set, and the answer to a
  // cancel's `abort` arrives after the share is over.
  property string sharePending: ""

  function applyShareResponse(exitCode, text) {
    var asked = root.sharePending
    if (asked === "") return
    root.sharePending = ""

    if (text.length > root.shareAnswerMax) {
      root.endShare("The share helper said more than it should have", false)
      return
    }

    if (asked === "begin") {
      root.applyShareBegun(exitCode, text)
      return
    }
    if (asked === "finish") {
      root.applyShareFinished(exitCode, text)
      return
    }
    // "abort" is the helper cleaning up after a cancel. There is nothing to
    // report: the user was already told the share was cancelled, and the only
    // thing left to do is let the run directory go.
  }

  function applyShareBegun(exitCode, text) {
    if (exitCode !== 0) {
      root.endShare("The map was not saved", false)
      return
    }
    // A `begin`: the run directory, then one absolute path per frame. Both
    // shapes are checked rather than believed — a path that is not a path, or
    // a count that is not the count asked for, is a helper behaving in a way
    // this panel does not understand, and a frame written somewhere else is
    // worse than no share.
    var lines = text.trim().split("\n")
    if (lines.length !== root.shareTotal + 1
      || !/^\/[^\n\t]{1,255}$/.test(lines[0])
      || !/^\/[^\n\t]{1,255}\.png$/.test(lines[1])) {
      root.endShare("The helper returned something unexpected", false)
      return
    }
    root.shareRunDir = lines[0].split("/").pop()
    root.sharePaths = lines.slice(1)
    root.captureNextFrame()
  }

  function applyShareFinished(exitCode, text) {
    if (exitCode !== 0) {
      root.endShare("The map was not saved", false)
      return
    }
    var answer = text.trim().split("\n")[0].split("\t")
    if (answer.length !== 2 || !/^\/[^\n\t]{1,255}\.(png|gif)$/.test(answer[0])
      || !/^[0-9]{1,12}$/.test(answer[1])) {
      root.endShare("The helper returned something unexpected", false)
      return
    }
    // The name is reduced to [a-z0-9-] by Share.fileName() before it ever
    // reaches a sink, so the notification quotes the file name without a
    // strip pass over a string built out of a remote layer title.
    root.endShare("Saved " + answer[0].split("/").pop(), true)
    clipboardProc.launch(["/usr/bin/wl-copy", "--type",
      answer[0].endsWith(".gif") ? "image/gif" : "image/png", answer[0]])
  }

  // The clipboard is the integration: a pasted image is a shared map without
  // the user opening a file manager to find it. wl-copy reads a named file, so
  // the path crosses as an argument and no image bytes do. Nothing comes back
  // out of it, which is why it collects no output.
  BoundedProcess {
    id: clipboardProc
  }

  // Which of the two share formats is offered, asked as a question because the
  // radar is the only view where the answer is not obvious. `ConfirmDialog` is
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    // The panel's key catcher turns keys into semantic signals rather than
    // exposing a hook for a dialog's own handler, so the chooser is driven
    // through the three signals it does emit. It stays the focus target: the
    // host hands focus to `focusTarget` and this is the one thing that has
    // always held it.
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(
      (root.settingsOpen ? settingsContent.implicitHeight : content.implicitHeight)
      + hintBar.implicitHeight + Style.space(12))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the search field has focus its keystrokes are text, not
      // shortcuts: without this, typing a city name would scrub the
      // timeline and zoom the map. Same for the settings fields, where
      // "s" would otherwise shut the page mid-edit, and for the first-run
      // prompt, where the question owns the whole keyboard.
    blocked: root.editingLocation || root.settingsHasFocus || root.locationPromptOpen
    // Escape, and the button in the hint row, both land here. The chooser is
    // answered by the keys handler below, so this is a second door to the same
    // answer rather than the only one. A share in progress means "stop that"
    // rather than "close this", because the share is the thing under the user's
    // hands and the thing that can take seconds; the panel can be closed a
    // second later.
    onCloseRequested: {
      if (shareChooser.opened) { root.shareChooser.opened = false; return }
      if (root.sharing) root.failShare("Share cancelled")
      else root.close()
    }
    onTabRequested: function(direction) {
      // Tab moves between the two options rather than to the neighbouring bar
      // panel, because the chooser is the only thing on screen that can be
      // acted on.
      if (shareChooser.opened) {
        shareChooser.selectedIndex = shareChooser.selectedIndex === 0 ? 1 : 0
        return
      }
      if (root.bar && typeof root.bar.switchPanelFrom === "function")
        root.bar.switchPanelFrom(root.barIdentity, direction)
    }
    onReturnRequested: {
      if (shareChooser.opened) {
        root.chooseShareFormat()
        return
      }
      if (root.radarMode) root.playing = !root.playing
    }

      Keys.onPressed: function(event) {
        // The chooser owns the keyboard while it is up. It has to be this
        // handler rather than the key catcher's signals, because the catcher
        // turns keys into meanings — scrub, zoom, play — and none of those mean
        // anything over a question asking which file to write.
        if (shareChooser.opened) {
          if (event.key === Qt.Key_Escape) root.shareChooser.opened = false
          else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
            shareChooser.selectedIndex = shareChooser.selectedIndex === 0 ? 1 : 0
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.chooseShareFormat()
          }
          event.accepted = true
          return
        }

        if (event.text === "s" || event.text === "S") {
          root.toggleSettings()
          event.accepted = true
        } else if (event.text === "p" || event.text === "P") {
          if (root.sharing) root.failShare("Share cancelled")
          else root.requestShare()
          event.accepted = true
        } else if (event.key === Qt.Key_Left && root.radarMode && !root.sharing) {
          root.setTimelineIndex(Math.max(0, root.timelineIndex - 1))
          event.accepted = true
        } else if (event.key === Qt.Key_Right && root.radarMode && !root.sharing) {
          root.setTimelineIndex(Math.min(root.timelineFrames.length - 1, root.timelineIndex + 1))
          event.accepted = true
        } else if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) {
          root.zoom = Math.min(RadarModel.MAX_MAP_ZOOM, root.zoom + 1)
          event.accepted = true
        } else if (event.key === Qt.Key_Minus) {
          root.zoom = Math.max(RadarModel.MIN_RADAR_ZOOM, root.zoom - 1)
          event.accepted = true
        } else if (event.key === Qt.Key_Home) {
          root.panned = false
          root.recenter()
          event.accepted = true
        }
      }

      // The panel scrolls when its content is taller than the screen — the map
      // column sits in here, and while the settings page is open this whole
      // side hides in favour of it. Mouse drags inside the map still pan the
      // map: its MouseArea accepts the press, which keeps the flick from
      // winning.
      Flickable {
        id: panelFlick
        anchors.fill: parent
        anchors.bottomMargin: hintBar.height + Style.space(10)
        visible: !root.settingsOpen
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: content
          width: parent.width
          spacing: Style.space(10)

          PanelHeader {
            width: parent.width
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fetching: root.fetching
            locationName: root.locationName
            updatedAgo: root.service ? root.service.latestUpdateAge : ""
            onLocationClicked: root.startEditingLocation()
          }

          MapCanvas {
            id: map
            width: parent.width
            height: root.mapHeight
            bar: root.bar
            basemap: root.basemap

            centerLatitude: root.viewLatitude
            centerLongitude: root.viewLongitude
            zoom: root.zoom
            overlaySourceZoom: root.overlaySourceZoom

            tileUrlA: root.tileUrlA
            tileUrlB: root.tileUrlB
            radarOverlayVisible: root.radarMode

            frameA: root.frameA
            frameB: root.frameB
            frameEpoch: root.frameEpoch
            frontIsA: root.frontIsA
            colorSchemeId: root.colorSchemeId
            smoothTiles: root.smoothTiles

            hasLocation: root.hasLocation
            homeLatitude: root.homeLatitude
            homeLongitude: root.homeLongitude
            alertsEnabled: root.alertsEnabled
            alertRadiusKm: root.alertRadiusKm

            overlayUnavailable: root.service ? root.service.frameFailures > 0 : false
            attribution: root.attribution

            airOverlayVisible: root.shownAirLayerName !== ""
            airLayerName: root.shownAirLayerName
            airStepTime: root.shownAirStepTime

            // The share. `exporting` puts the legend inside the grab and a
            // veil over the map while frames are being captured; the legend
            // fields are the same ones the panel's own strip below is bound
            // to, so the two cannot disagree about what the map is drawing.
            exporting: root.sharing
            legendMode: root.airShown ? root.activeCategory : "radar"
            legendLabel: root.activeLayer ? CamsModel.layerLabel(root.activeLayer) : ""
            legendSpecies: root.activeLayer ? (root.activeLayer.species || "") : ""
            onShareRequested: root.requestShare()

            onDragged: function(latitude, longitude) {
              root.viewLatitude = TileMath.constrainLatitude(latitude, root.zoom, root.mapHeight)
              // Normalised as it is stored, so panning east indefinitely keeps
              // the centre a real coordinate rather than letting it grow
              // without bound. The ground draws the world repeatedly either
              // way; this is about what everything else positioned against the
              // centre sees.
              root.viewLongitude = TileMath.wrapLongitude(longitude)
              root.panned = true
            }
            onRecenterRequested: {
              root.panned = false
              root.recenter()
            }

            // The staged frame finished loading: the swap may go ahead. The
            // callLater matters — a model rebuild first destroys the old tile
            // delegates and then creates the new ones, and between those halves
            // the layer can briefly report ready with nothing counted yet.
            // Deferring to the end of the event loop turn and looking again
            // reads the settled count instead of the transient.
            onBackReadyChanged: if (map.backReady) Qt.callLater(root.commitIfReady)
            onZoomRequested: function(zoom, latitude, longitude) {
              root.zoom = zoom
              var wrapped = TileMath.wrapLongitude(longitude)
              // Zooming towards the pointer moves the view, so it counts as
              // panning — otherwise the next location update would snap the
              // map back. Zooming on the centre moves nothing and must not.
              var constrained = TileMath.constrainLatitude(latitude, zoom, root.mapHeight)
              if (!TileMath.samePosition(constrained, wrapped, root.viewLatitude, root.viewLongitude)) {
                root.viewLatitude = constrained
                root.viewLongitude = wrapped
                root.panned = true
              }
            }

            CoverageProbe {
              id: coverageProbe
              source: root.coverageProbeUrl
              onResolved: function(covered) {
                if (root.service && root.service.reportCoverage) root.service.reportCoverage(covered)
                if (!covered) console.log("akash: no ground radar reaches the configured location")
              }
            }
          }

          // The map's legend, docked as a colour strip under the map: it names
          // whichever ramp the map is drawing, in the same column and at the same
          // width, so it reads as part of the map without covering any of it.
          //
          // While a share is running this row is replaced by the progress
          // line, and the strip moves inside the map (ui/MapCanvas.qml) where
          // the grab can reach it. The progress line is deliberately not there:
          // it would be photographed into every frame of the loop.
          LegendStrip {
            width: parent.width
            visible: !root.sharing
            bar: root.bar
            mode: root.airShown ? root.activeCategory : "radar"
            layerLabel: root.activeLayer ? CamsModel.layerLabel(root.activeLayer) : ""
            layerSpecies: root.activeLayer ? (root.activeLayer.species || "") : ""
          }

          // What a share is doing, and how to stop it. Shares take a few
          // seconds — long enough that a control which does nothing looks
          // broken, so the affordance to cancel is on screen rather than only
          // on Escape.
          Row {
            width: parent.width
            visible: root.sharing
            spacing: Style.space(10)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - cancelShare.width - Style.space(10)
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.shareMode === "gif"
                ? "Rendering frame " + root.shareDone + " of " + root.shareTotal
                : "Rendering…"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Button {
              id: cancelShare
              anchors.verticalCenter: parent.verticalCenter
              text: "cancel"
              fontFamily: Style.font.family
              foreground: Color.foreground
              background: Color.popups.background
              bordered: true
              onClicked: root.failShare("Share cancelled")
            }
          }

          LayerPicker {
            width: parent.width
            bar: root.bar
            categories: root.chipCategories
            activeCategory: root.activeCategory
            layers: root.camsLayers
            selectedLayerName: root.activeLayer ? root.activeLayer.name : ""

            onCategoryChosen: function(id) { root.chooseCategory(id) }
            onLayerChosen: function(layer) {
              if (layer) root.setSelectedLayer(root.activeCategory, layer.name)
            }
            onLayerCleared: root.clearAirOverlay()
          }

          Timeline {
            width: parent.width
            bar: root.bar
            replayable: root.radarMode
            frames: root.timelineFrames
            frameIndex: root.timelineIndex
            playing: root.playing
            frameLabel: root.timelineLabel
            frameAgo: root.timelineAgo
            isLatestFrame: root.timelineAtLatest
            // The stamp box reserve pins the slider's anchor chain. The
            // widest line is the "ago" caption ("1 h 55 m ago", ~56px at its
            // 8.5px size), so 72px fits with slack.
            labelWidth: Style.space(72)
            onPlayToggled: root.playing = !root.playing
            onFrameRequested: function(index) { root.setTimelineIndex(index) }
          }
        }
      }

      // The settings page: a dedicated page that replaces the map column
      // while it is open, reached by the S key or the hint cap at the foot.
      // It swaps the whole panel rather than appending below the alert
      // controls, so the controls are never far from the scroll and the
      // page reads as its own screen. The main content above hides while
      // it is open.
      Flickable {
        id: settingsPage
        anchors.fill: parent
        anchors.bottomMargin: hintBar.height + Style.space(10)
        visible: root.settingsOpen
        contentWidth: width
        contentHeight: settingsContent.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Item {
          width: parent.width
          height: settingsContent.implicitHeight

          Column {
            id: settingsContent
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "SETTINGS"
              foreground: root.settingsForeground
              fontFamily: Style.font.family
            }

            Column {
              width: parent.width
              spacing: Style.space(10)
              leftPadding: Style.space(16)
              rightPadding: Style.space(16)

              Grid {
                columns: 2
                columnSpacing: Style.space(12)
                rowSpacing: Style.space(10)
                width: parent.width - parent.leftPadding - parent.rightPadding

                Column {
                  width: parent.width / 2 - Style.space(6)
                  spacing: Style.space(4)

                  Text {
                    textFormat: Text.PlainText
                    text: "OPEN PANEL ON"
                    color: Qt.darker(root.settingsForeground, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                  }

                  Dropdown {
                    id: settingsViewField
                    width: parent.width
                    value: root.defaultView
                    options: root.viewOptions
                    foreground: root.settingsForeground
                    fontFamily: Style.font.family
                    showLabel: false
                    onChanged: function(v) { root.persistSetting("defaultView", v) }
                  }
                }

                Column {
                  width: parent.width / 2 - Style.space(6)
                  spacing: Style.space(4)

                  Text {
                    textFormat: Text.PlainText
                    text: "DEFAULT ZOOM"
                    color: Qt.darker(root.settingsForeground, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                  }

                  NumberField {
                    id: settingsZoomField
                    width: parent.width
                    value: root.defaultZoomSetting
                    from: RadarModel.MIN_RADAR_ZOOM
                    to: RadarModel.MAX_MAP_ZOOM
                    stepSize: 1
                    foreground: root.settingsForeground
                    fontFamily: Style.font.family
                    label: ""
                    onModified: function(v) { root.persistSetting("defaultZoom", v) }
                  }
                }
              }

              Column {
                width: parent.width - parent.leftPadding - parent.rightPadding
                spacing: Style.space(10)

                // Full-width rows rather than a 3-across squeeze: at the
                // panel's width a third shares ~85px of label space, which
                // elides "Distinguish snow" into "Distinguish…". The kit's
                // Toggle idiom is title + description left, switch right.
                Toggle {
                  width: parent.width
                  label: "Smooth radar"
                  description: "Blend the radar image instead of hard pixel edges."
                  foreground: root.settingsForeground
                  accent: Color.accent
                  fontFamily: Style.font.family
                  checked: root.smoothTiles
                  onClicked: root.persistSetting("smoothTiles", !root.smoothTiles)
                }

                Toggle {
                  width: parent.width
                  label: "Distinguish snow"
                  description: "Colour snow separately from rain."
                  foreground: root.settingsForeground
                  accent: Color.accent
                  fontFamily: Style.font.family
                  checked: root.showSnow
                  onClicked: root.persistSetting("showSnow", !root.showSnow)
                }

                Toggle {
                  width: parent.width
                  label: "Status text"
                  description: "Print the outlook beside the bar icon (needs storm alerts)."
                  foreground: root.settingsForeground
                  accent: Color.accent
                  fontFamily: Style.font.family
                  checked: root.showLabelInBar
                  onClicked: root.persistSetting("showLabel", !root.showLabelInBar)
                }
              }
            }

            PanelSeparator { width: parent.width }

            // Location and the two watches live here too now, one rail under
            // the display settings: the panel's main page is just the map,
            // this page is everything else.
            Column {
              width: parent.width
              spacing: Style.space(6)
              leftPadding: Style.space(16)
              rightPadding: Style.space(16)

              PanelSectionHeader {
                text: "LOCATION"
                foreground: root.settingsForeground
                fontFamily: Style.font.family
              }

              LocationPicker {
                id: locationPicker
                width: parent.width
                spacing: Style.space(6)
                bar: root.bar
                locationName: root.locationName
                locationState: root.locationState
                coverageMissing: root.coverageMissing
                editing: root.editingLocation
                saving: root.savingLocation
                editingMode: root.locationEditMode
                suggestions: root.locationSuggestions
                suggestionIndex: root.suggestionIndex
                coordinateError: root.coordinateError

                onEditRequested: root.startEditingLocation()
                onCancelRequested: root.cancelEditingLocation()
                onCommitRequested: root.commitLocation()
                onClearRequested: root.clearLocation()
                onQueryEdited: geocodeDebounce.restart()
                onSuggestionHighlighted: function(index) { root.suggestionIndex = index }
                onSuggestionPicked: function(suggestion) { root.pickSuggestion(suggestion) }
                onModeSwitchRequested: function(mode) { root.switchLocationEditMode(mode) }
                onCoordinateCommitRequested: root.commitCoordinates()
              }
            }

            PanelSeparator { width: parent.width }

            AlertControls {
              width: parent.width
              // Sections need more air between them than rows do inside one.
              spacing: Style.space(12)
              bar: root.bar
              service: root.service
              alertsEnabled: root.alertsEnabled
              locationState: root.locationState
              alertLeadMinutes: root.alertLeadMinutes
              alertRadiusKm: root.alertRadiusKm
              radiusPresets: root.radiusPresets
              alertThreshold: root.alertThreshold
              thresholdOptions: root.thresholdOptions

              onAlertsToggled: {
                var next = !root.alertsEnabled
                root.persistSetting("alertsEnabled", next)
                // Fire the first check immediately so enabling produces a
                // visible result instead of up to ten minutes of silence.
                if (next && root.service && root.service.checkNow) Qt.callLater(root.service.checkNow)
              }
              // The service watches for these and re-checks on its own, so a
              // value edited into shell.json by hand behaves the same as one
              // chosen here.
              onRadiusChosen: function(km) { root.persistSetting("alertRadiusKm", km) }
              onThresholdChosen: function(name) { root.persistSetting("alertMinIntensity", name) }

              aqAlertsEnabled: root.aqAlertsEnabled
              aqBandName: root.aqBandName
              aqBandOptions: root.aqBandOptions

              onAqAlertsToggled: {
                var next = !root.aqAlertsEnabled
                root.persistSetting("aqAlertsEnabled", next)
                // Enabling answers with the reading in hand, if there is one —
                // the probe cadence is hourly, too long to wait for a first word.
                if (next && root.service && root.service.evaluateAqAlert) Qt.callLater(root.service.evaluateAqAlert)
              }
              onAqBandChosen: function(name) { root.persistSetting("aqAlertBand", name) }
            }
          }
        }
      }

      Row {
        id: hintBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Style.space(16)
        anchors.rightMargin: Style.space(16)
        spacing: Style.space(10)

        Row {
          spacing: Style.space(6)
          KeyCap { label: "S"; onActivated: root.toggleSettings() }
          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: root.settingsOpen ? "close settings" : "settings"
            color: Qt.darker(root.settingsForeground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption

            // The label is a hint, but a clickable one: the keycap beside it
            // already toggles, and the whole affordance should too, the way
            // oma.quake's hint row works.
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleSettings()
            }
          }

          // Share, on the same terms: a keycap and a label, both live. This
          // one earns its place more than the others do — the button in the
          // corner of the map is small, and a map worth sharing is usually a
          // map somebody has just scrubbed to, which is a keyboard action.
          KeyCap { label: "P"; onActivated: root.requestShare() }
          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: root.sharing ? "cancel share" : "share map"
            color: Qt.darker(root.settingsForeground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.sharing) root.failShare("Share cancelled"); else root.requestShare()
            }
          }
        }
      }

      // The first-run question box: a dim scrim over the whole panel with a
      // centred card asking for the city. It sits above both pages and the
      // hint bar. Clicking the scrim answers nothing except "later".
      Rectangle {
        id: locationPromptScrim
        visible: root.locationPromptOpen
        anchors.fill: parent
        color: Util.alpha(root.settingsForeground, 0.18)
        z: 100

        MouseArea {
          anchors.fill: parent
          onClicked: root.dismissLocationPrompt()
        }

        Rectangle {
          id: locationPromptCard
          anchors.centerIn: parent
          width: Math.min(Style.space(380), parent.width - Style.space(32))
          height: locationPromptContent.implicitHeight + Style.space(24) * 2
          radius: Style.cornerRadius
          color: Color.popups.background
          border.color: Color.popups.border
          border.width: 1

          // Swallow clicks on the card's non-interactive spaces so they do
          // not fall through to the scrim and dismiss the box mid-read.
          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
          }

          Column {
            id: locationPromptContent
            width: parent.width - Style.space(24) * 2
            anchors.centerIn: parent
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Where are you?"
              color: root.settingsForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Akash has no location yet. Set a city and the radar, " +
                    "alerts and air-quality reading all know where to look."
              color: Qt.darker(root.settingsForeground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            TextField {
              id: locationPromptField
              width: parent.width
              placeholderText: "Search city"
              foreground: root.settingsForeground
              accent: Color.accent
              font.family: Style.font.family
              text: root.locationPromptQuery

              onTextChanged: {
                root.locationPromptQuery = text
                geocodeDebounce.restart()
              }

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.dismissLocationPrompt()
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.commitLocationPrompt()
                  event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  if (root.suggestionIndex < root.locationSuggestions.length - 1) {
                    root.suggestionIndex = root.suggestionIndex + 1
                  }
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  if (root.suggestionIndex > 0) root.suggestionIndex = root.suggestionIndex - 1
                  event.accepted = true
                }
              }
            }

            Repeater {
              model: root.locationSuggestions

              Rectangle {
                required property var modelData
                required property int index

                readonly property bool highlighted: index === root.suggestionIndex

                width: parent.width
                height: promptSuggestionRow.implicitHeight + Style.space(8)
                radius: Style.space(4)
                color: highlighted ? Style.hoverFillFor(root.settingsForeground, Color.accent) : "transparent"

                Row {
                  id: promptSuggestionRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    width: parent.width / 2
                    text: modelData.name
                    color: highlighted
                      ? Style.hoverStateColor(root.settingsForeground, Color.accent)
                      : root.settingsForeground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    width: parent.width - parent.width / 2 - Style.space(8)
                    text: modelData.description
                    color: Qt.darker(root.settingsForeground, 1.5)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: root.suggestionIndex = index
                  onClicked: root.promptPickSuggestion(modelData)
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: "Skip"
                fontSize: Style.font.bodySmall
                fontFamily: Style.font.family
                foreground: root.settingsForeground
                background: Color.popups.background
                bordered: true
                onClicked: root.dismissLocationPrompt()
              }

              Button {
                text: "Save city"
                fontSize: Style.font.bodySmall
                fontFamily: Style.font.family
                foreground: root.settingsForeground
                accent: Color.accent
                background: Color.popups.background
                onClicked: root.commitLocationPrompt()
              }
            }
          }
        }
      }

      // The share chooser, as the last child of the window that holds the map.
      //
      // This placement is the whole reason it works. `KeyboardPanel` is a
      // PanelWindow — a separate window, not an item in this one — so a dialog
      // declared out at the panel's own level would be in a different window
      // from the map, and no `z` would ever raise it above one. Declared in
      // here it shares that window, and `z` does the rest: the key catcher
      // above fills it with the map and its own mouse handling, so without a z
      // the dialog would open, paint underneath, and eat no clicks — which
      // looks exactly like the share button doing nothing. The host places its
      // own dialogs the same way; see the clipboard plugin's clear-history
      // prompt.
      ConfirmDialog {
        id: shareChooser
        z: 10
        anchors.fill: parent
        message: "Share this map as"
        cancelText: "PNG image"
        confirmText: "Animated GIF"
        selectedIndex: 1
        onConfirmed: root.startShare("gif")
        // The two buttons and the dismissing gestures all arrive as one signal
        // pair, and they are not the same thing:
        //
        //   confirmed()  the right button   — Animated GIF
        //   canceled()   the left button    — PNG image
        //   canceled()   a click on the scrim — neither
        //
        // So the left button cannot simply be treated as a dismissal, or
        // "PNG image" closes the dialog and shares nothing — which is exactly
        // what it did. `selectedIndex` is what tells the button from the scrim:
        // a button sets the index to its own position as it is pressed, and the
        // scrim leaves it where it was, which is 1 unless the reader moved it.
        //
        // Escape never comes here. It is handled in the key catcher above,
        // which closes the dialog without calling handleKey, so there is no
        // way for it to be read as a choice.
        onCanceled: {
          if (shareChooser.selectedIndex === 0) root.startShare("image")
          else root.shareChooser.opened = false
        }
      }
    }
  }

  // The keycap hint chip, as oma.quake draws it: a bordered surface around a
  // caption letter, clickable. Inline components declared inside the root stay
  // in scope for the panel tree.
  component KeyCap: BorderSurface {
    id: keyCap
    signal activated()
    property alias label: keyText.text

    implicitWidth: Math.max(keyText.implicitWidth + Style.space(8), implicitHeight)
    implicitHeight: keyText.implicitHeight + Style.space(4)
    color: capMouse.containsMouse ? Style.hoverFillFor(root.settingsForeground, Color.accent) : "transparent"
    borderSpec: Border.flat(Qt.darker(root.settingsForeground, 1.5), Style.normalBorderWidth)
    radius: Style.space(3)

    Text {
      id: keyText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      color: Qt.darker(root.settingsForeground, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    MouseArea {
      id: capMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: keyCap.activated()
    }
  }

}
