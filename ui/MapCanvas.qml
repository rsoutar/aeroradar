import QtQuick
import qs.Commons
import qs.Ui
import "../lib/Glyphs.js" as Glyphs
import "../lib/RadarModel.js" as RadarModel
import "../lib/TileMath.js" as TileMath

// The map itself: a basemap, animated overlay frames stacked over it, the
// alert rings around home, and the drag and wheel gestures that move the view.
//
// The panel owns the view — where it is centred and how far in it is zoomed —
// because the keyboard shortcuts and the recentre button move it too. This
// renders that view and reports the gestures made on it.
Item {
  id: root

  property var bar: null

  // The decoded ground, owned by the service. Null until its first layer has
  // been decoded, then filled in layer by layer over a second or so — the
  // map is open sea for a moment, then land, then what sits on it.
  property var basemap: null

  // Where the map is looking.
  property real centerLatitude: 0
  property real centerLongitude: 0
  property int zoom: 7

  // The zoom the overlay tiles are requested at. Radar resolution runs out
  // before the map does, so past that limit the radar layers keep asking for
  // their deepest real tiles and get scaled up over a basemap that is still
  // sharpening.
  property int overlaySourceZoom: zoom

  // function(zoom, x, y) -> string, one per crossfade half. Generic rather
  // than radar-specific on purpose: the air-quality overlay fades the same
  // pair of tile layers when it arrives.
  property var tileUrlA: null
  property var tileUrlB: null

  // Radar and CAMS are exclusive map modes. Keep this explicit at the
  // rendering boundary so a crossfade that was in progress cannot leave a
  // radar frame visible after Air Quality takes ownership.
  property bool radarOverlayVisible: true

  // Which of the two layers holds which frame, and which is in front. Bumping
  // a layer's frame while it is behind, then swapping, is what makes the loop
  // dissolve instead of flicker.
  property int frameA: -1
  property int frameB: -1
  property bool frontIsA: true

  // Whether the layer holding the staged (behind) frame has finished loading
  // its tiles. The panel swaps only when this is true, so the crossfade runs
  // between two fully drawn frames instead of fading to the bare ground.
  readonly property bool backReady: frontIsA ? overlayB.ready : overlayA.ready

  // Changes when the frame list is replaced. Folded into each layer's
  // revision so that a new manifest reloads the tiles even when the index did
  // not move.
  property int frameEpoch: 0
  // Bumped to retry a tile layer that stalled. Folded into the revision AND
  // into the URL the panel builds, so a retry is a fresh request rather than
  // another look at the stuck cache entry. Owned here — the layers share it,
  // and whoever is asking for a refresh (the panel on open) can reset it.
  property int tileRetry: 0
  readonly property int maxTileRetries: 2

  function retryTiles() {
    // Capped so a dead network retries a bounded number of times and then
    // shows the honest empty map. The layer has already settled itself.
    if (root.tileRetry < root.maxTileRetries) root.tileRetry++
  }

  property int colorSchemeId: 2
  property bool smoothTiles: true

  // Home, and the rings around it.
  property bool hasLocation: false
  property real homeLatitude: 0
  property real homeLongitude: 0
  property bool alertsEnabled: false
  property int alertRadiusKm: 100

  // Whether the frame list is absent because fetching it failed rather than
  // because it has not arrived yet. The header reads "Fetching" while the list
  // is on its way and must stop once the fetch is known to have failed rather
  // than blink forever, which is what this tells the panel.
  //
  // Only the list. Whether the tiles under it can be fetched is deliberately
  // not reported: the layers cache by URL, so a map holding frames it
  // fetched before goes on drawing them with no network at all — correctly,
  // and with the frame's own time under it.
  property bool overlayUnavailable: false

  // Whether the map is pulling *new* data. Only the CAMS overlay: radar tiles
  // are cached by URL and merely re-decode when a chip returns to Radar, which
  // is not a fetch and would otherwise blink the header every time. The
  // overlay is a fresh GetMap per viewport and step, so it is a real request.
  readonly property bool fetching: airLayer.loading

  property string attribution: ""

  // The CAMS overlay, owned by the panel: which layer, which forecast step,
  // how opaque. Off entirely when no layer is selected.
  property bool airOverlayVisible: false
  property string airLayerName: ""
  property string airStepTime: ""

  signal dragged(real latitude, real longitude)
  signal recenterRequested()

  // Zooming carries a centre because the wheel zooms towards the pointer,
  // not towards the middle of the map. Someone reaching for a coastal town
  // does not want the sea their view happens to be centred on.
  signal zoomRequested(int zoom, real latitude, real longitude)

  readonly property color foreground: bar ? bar.foreground : Color.foreground

  // ---- Sharing ----------------------------------------------------------
  //
  // A share is a grab of this item: `Item.grabToImage` renders the item and
  // its children, so the basemap, the radar frame, the air overlay, the rings
  // and the credit line under it are all composited by Qt into one PNG. There
  // is no second map to keep in step with this one and nothing to resize or
  // draw in the helper.
  //
  // That is also why the legend has to be here rather than left in the panel
  // column: the panel's own strip is a sibling of this item, so a grab of this
  // item cannot see it. The overlay below carries the same strip in, visible
  // only while a share is running, which is the only time it is wanted in the
  // picture. An air-quality overlay without its scale is a picture of nothing
  // in particular.
  property bool exporting: false

  // The resolution an export is being taken at, as a multiple of the map's own
  // pixels. Only the air overlay has anything to spend it on — the WMS renders
  // whatever it is asked for — so this is the scale its GetMap goes out at, and
  // 1 the rest of the time.
  property real exportScale: 1

  // The air layer is done trying, either because it has the picture at
  // `exportScale` or because it has run out of ways to get one. The panel owns
  // the capture and cannot see the layer, so the map passes it on.
  signal airSettled()
  readonly property bool airStale: airLayer.stale

  property string legendMode: "radar"
  property string legendLabel: ""
  property string legendSpecies: ""

  // The panel owns the capture; the map only says it was asked for.
  signal shareRequested()

  Rectangle {
    id: canvasFrame
    anchors.fill: parent
    // The same tone the ground layer paints its sea with, so the corners it
    // cannot reach match rather than showing through as a hole.
    color: ground.seaColor
    radius: Style.cornerRadius
    clip: true

    BasemapLayer {
      id: ground
      anchors.fill: parent
      basemap: root.basemap
      centerLatitude: root.centerLatitude
      centerLongitude: root.centerLongitude
      zoom: root.zoom
    }

    TileLayer {
      id: overlayA
      anchors.fill: parent
      active: root.radarOverlayVisible
      visible: root.radarOverlayVisible
      centerLatitude: root.centerLatitude
      centerLongitude: root.centerLongitude
      zoom: root.zoom
      sourceZoom: root.overlaySourceZoom
      tileUrlFor: root.tileUrlA
      revision: root.frameA + (root.colorSchemeId * 1000) + (root.frameEpoch * 100000)
        + (root.tileRetry * 1000000)
      smooth: root.smoothTiles
      opacity: root.frontIsA ? 1 : 0
      onStalled: root.retryTiles()
      Behavior on opacity {
        NumberAnimation { duration: 380; easing.type: Easing.InOutQuad }
      }
    }

    TileLayer {
      id: overlayB
      anchors.fill: parent
      active: root.radarOverlayVisible
      visible: root.radarOverlayVisible
      centerLatitude: root.centerLatitude
      centerLongitude: root.centerLongitude
      zoom: root.zoom
      sourceZoom: root.overlaySourceZoom
      tileUrlFor: root.tileUrlB
      revision: root.frameB + (root.colorSchemeId * 1000) + (root.frameEpoch * 100000)
        + (root.tileRetry * 1000000)
      smooth: root.smoothTiles
      opacity: root.frontIsA ? 0 : 1
      onStalled: root.retryTiles()
      Behavior on opacity {
        NumberAnimation { duration: 380; easing.type: Easing.InOutQuad }
      }
    }

    // The CAMS overlay sits over the radar tiles: one viewport-sized image
    // per forecast step, hidden while the view moves under it. See
    // ui/AirLayer.qml for why it is a GetMap image rather than tiles.
    AirLayer {
      id: airLayer
      anchors.fill: parent
      active: root.airOverlayVisible
      centerLatitude: root.centerLatitude
      centerLongitude: root.centerLongitude
      zoom: root.zoom
      layerName: root.airLayerName
      stepTime: root.airStepTime
      // A share is about to photograph this at `exportScale`, so the GetMap
      // goes out at that size rather than at the size of what is on screen.
      requestScale: root.exporting ? root.exportScale : 1
      onSettled: root.airSettled()
    }

    // ---- Alert rings and home marker ------------------------------------
    Item {
      id: homeOverlay
      anchors.fill: parent
      visible: root.hasLocation

      // The copy of home nearest the centre. Two points either side of the
      // antimeridian are a couple of degrees apart on the globe and 358
      // apart in their coordinates, so without this a map centred just east
      // of the line puts the marker most of a world away.
      readonly property var home: TileMath.projectToViewport(
        root.homeLatitude,
        TileMath.nearestLongitude(root.homeLongitude, root.centerLongitude),
        root.centerLatitude, root.centerLongitude,
        root.zoom, width, height)

      readonly property real ringRadius: TileMath.kmToPixels(
        root.alertRadiusKm, root.homeLatitude, root.zoom)

      // Outer ring is the configured alert radius; the inner half-ring gives
      // a sense of scale.
      Repeater {
        model: [0.5, 1.0]

        Rectangle {
          required property real modelData
          readonly property real r: homeOverlay.ringRadius * modelData
          x: homeOverlay.home.x - r
          y: homeOverlay.home.y - r
          width: r * 2
          height: r * 2
          radius: r
          color: "transparent"
          border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b,
            modelData === 1.0 ? 0.55 : 0.3)
          border.width: 1
          visible: root.alertsEnabled && r > 6 && r < homeOverlay.width * 2
        }
      }

      Rectangle {
        readonly property real dot: Style.space(7)
        x: homeOverlay.home.x - dot / 2
        y: homeOverlay.home.y - dot / 2
        width: dot
        height: dot
        radius: dot / 2
        color: Color.accent
        // Outlined in the surface's own colour so the marker stays legible
        // over a dark coastline and a light one alike.
        border.color: Color.popups.background
        border.width: 1
      }
    }

    // ---- The export legend -----------------------------------------------
    // Docked at the foot of the map, the same width as the strip in the panel
    // column, and hidden whenever no share is running — so a grab without an
    // export in progress is exactly the map the user is looking at.
    //
    // One sibling rather than an overlay wrapping both this and a veil, because
    // the legend anchors to the credit line and QML only lets an item anchor to
    // a parent or a sibling.
    //
    // There is deliberately no veil over the map. A veil is the obvious way to
    // say "this is being captured", and it is wrong here for a reason that only
    // shows up in the artefact: it would be composited into the grab along with
    // everything else, so every frame of a shared loop — and the shared still —
    // would be 25% darker than the map the person was looking at. The progress
    // row under the map says the same thing and is not in the picture.
    LegendStrip {
      anchors.left: parent.left
      anchors.right: parent.right
      // Above the credit line rather than over it. The strip is as wide as the
      // map and sits at the bottom of it, which is where the credit line
      // already is — and a share is exactly the case where both end up in the
      // same picture, so the collision would only ever show up in the artefact.
      anchors.bottom: creditLine.top
      anchors.bottomMargin: Style.space(4)
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      visible: root.exporting
      bar: root.bar
      mode: root.legendMode
      layerLabel: root.legendLabel
      layerSpecies: root.legendSpecies
    }

    // ---- Pan and zoom ---------------------------------------------------
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

      property real lastX: 0
      property real lastY: 0

      onPressed: function(mouse) {
        lastX = mouse.x
        lastY = mouse.y
      }

      onPositionChanged: function(mouse) {
        if (!pressed) return
        var dx = mouse.x - lastX
        var dy = mouse.y - lastY
        if (dx === 0 && dy === 0) return
        lastX = mouse.x
        lastY = mouse.y

        // Convert the drag into a new centre by asking which coordinate now
        // sits under the middle of the viewport.
        var moved = TileMath.unprojectFromViewport(
          width / 2 - dx, height / 2 - dy,
          root.centerLatitude, root.centerLongitude,
          root.zoom, width, height)
        root.dragged(moved.latitude, moved.longitude)
      }

      onWheel: function(wheel) {
        wheel.accepted = true

        var direction = wheel.angleDelta.y > 0 ? 1 : -1
        var next = Math.max(RadarModel.MIN_RADAR_ZOOM,
          Math.min(RadarModel.MAX_MAP_ZOOM, root.zoom + direction))
        if (next === root.zoom) return

        // Which coordinate is under the pointer now, and where the map has
        // to be centred for it to still be under the pointer afterwards.
        var anchor = TileMath.unprojectFromViewport(
          wheel.x, wheel.y, root.centerLatitude, root.centerLongitude,
          root.zoom, width, height)
        var moved = TileMath.centerForPoint(
          anchor.latitude, anchor.longitude, wheel.x, wheel.y, next, width, height)

        root.zoomRequested(next, moved.latitude, moved.longitude)
      }
    }

    // ---- Overlays -------------------------------------------------------
    // The same affordance every map has, because the keyboard shortcut for
    // it is not discoverable and someone who has panned away has no other
    // way back short of retyping their city.
    // Note: the colour legend is not here. It is docked under this map in the
    // panel (Panel.qml) so it reads as part of the map without covering it.
    Button {
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(6)
      // Hidden while a share is running, which is a second reason beyond it
      // being in the way: a grab composites this item and its children, so a
      // crosshair in the corner of a shared map is a picture of the viewer's
      // own controls, and it lands on top of the export legend.
      visible: root.hasLocation && !root.exporting
      text: Glyphs.RECENTER
      fontFamily: Style.font.family
      foreground: root.foreground
      background: Color.popups.background
      bordered: true
      tooltipText: "Centre on your location (Home)"
      onClicked: root.recenterRequested()
    }

    // Share, on the opposite corner from recentre so the two map gestures do
    // not sit in a row. Top right rather than bottom, because the bottom is
    // already spoken for twice over — the recentre button, and the credit line
    // that a share has to carry out of the panel with it.
    Button {
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(6)
      // Gone rather than disabled, for the same reason as the recentre button
      // above: a shared map should not contain a picture of the share button.
      visible: !root.exporting
      text: Glyphs.SHARE
      fontFamily: Style.font.family
      foreground: root.foreground
      background: Color.popups.background
      bordered: true
      tooltipText: "Share this map (P)"
      onClicked: root.shareRequested()
    }

    Text {
      id: creditLine
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(6)
      text: root.attribution
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption * 0.8
      opacity: 0.4
    }

    // The failure state only. "Loading radar…" is the header's "Fetching" now;
    // an empty map in a radar-free region still says so on the map itself.
    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      visible: root.overlayUnavailable
      text: "Radar unavailable"
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      opacity: 0.6
    }
  }
}
