# Akash design

How a change, feature, or fix should behave.

[README.md](README.md) is install and use. [manifest.json](manifest.json) is
the settings schema. [SKILL.md](SKILL.md) is the operating manual. Honor these;
ask before violating them.

## Picture

Weather occupies the view. Geographic detail stays quiet: a Natural Earth
1:10 m basemap drawn in the theme's line weight, sparse labels, rings for the
alert radius, a crosshair, a timeline. Chrome — the bar pill, the panel —
follows the Omarchy theme.

Radar colours come from one place: the `COLOR_SCHEMES` table in
`lib/RadarModel.js`, selected by the widget's `colorScheme` setting and applied
to every radar tile request. The air legend cannot derive its colours from a
table of its own: the CAMS overlay is rendered by ECMWF, so the legend paints
the scale the map is actually drawn with, read from each layer's `GetLegend`
image into `CAMS_SCALES` in `lib/CamsModel.js`. The bar pill and the air-quality
alert still grade by the EEA bands — `BAND_NAMES`/`BAND_COLORS` in the same
file — so "Poor" means the same thing in the pill, the notification and the
settings. The bar pill does not paint with the EEA pastels, which wash out on
light themes: it signals severity with the theme's `Color.accent` and
`Color.urgent`, and its tooltip names the band exactly. A colour change to
either table is shown with a capture, not described.

Show actual frame and timeline times. The timeline stamp shows the frame's
own clock (`ui/Timeline.qml`), plus "35 min ago" when a radar frame sits
behind the newest. Only the radar has a transport: past frames replay
through the scrubber, while a CAMS forecast is never scrubbed — the air
overlay always serves the step nearest now, re-centred whenever the layer
or its forecast list changes. An empty map is ambiguous, so the plugin says
which it is:
the header's "Fetching" while frames are on their way, "Radar unavailable" on
the map when fetching them failed, and "· no radar coverage" where the
coverage probe found no ground radar. A clear sky is a real radar image that
shows nothing falling; an empty map in a radar-free part of the world means
"nothing is known", not "nothing is falling".

The panel's top line (`ui/PanelHeader.qml`) carries the plugin's name and its
live state: a terminal-style blinking dot, green and reading "Live" when idle,
orange and reading "Fetching" while any request is in flight. The green and
orange are fixed literals because the theme palette exposes no such roles; the
name and label stay on the theme's foreground. The configured location sits
dimmed right of the name (the LOCATION section's resting row shows only its
warnings now) and clicking either starts the location search; a long saved
name elides before it reaches the status cluster, so the header is always one
line. Between the location and the cluster a dim readout says when the newest
radar frame was published — "just now", "10 min ago" — fed by the service and
speaking in the timeline's own five-minute blocks; it never bloats the row,
because the city yields to it exactly as it yields to the cluster. The map
does not repeat the header's readouts.
"Fetching" tracks real requests — the
service's polls, a location save, and the CAMS overlay's GetMap — not radar
tile rendering: those tiles are cached by URL and merely re-decode when a chip
returns to Radar, so counting them would blink the header on every switch.
Work that finishes inside half a second is ignored too, so a fast request does
not flash the label.

Preferences the panel does not otherwise touch live in a dedicated settings
page opened by the S key or its hint-cap at the foot of the panel, the way
oma.quake's does: the page replaces the map column while it is open — a full
swap rather than a section appended to the bottom of the scroll. Everything
that is not the map lives there: the display settings (which view the panel
opens on, the radar palette, the default zoom, the smooth-radar / snow /
bar-label switches), the location picker, and the storm and air-quality alert
controls; the main page is the header, the map, the legend, the layer picker
and the timeline. The S hint-cap sits at the foot of both pages, reading
"settings" / "close settings", and both it and its label are clickable. An
open page edit owns the keyboard: typing "s" in a settings field edits, it
does not close the page. Clicking the location in the header jumps to the
settings page with the picker already editing.

A fresh install with no location anywhere is asked for its city once: the
first time the panel opens, a question box covers it asking "Where are you?",
with the same geocoder and suggestion rows as the picker. Answering or
skipping both set `locationPrompted`, so the question never reappears — the
location is Omarchy's shared file afterwards, and the picker edits it there.

Keep attribution: data credits (RainViewer, Open-Meteo, Copernicus
CAMS/ECMWF, Natural Earth) in README's data-sources section, and code credits
(kuki, omarchy-weather-radar) in README's credits and in LICENSE. The map
carries its own credit line too, and it is per view — RainViewer over Natural
Earth, or Copernicus CAMS/ECMWF over Natural Earth — because on screen that
line is a caption in the corner and in a shared file it is the difference
between an attributed picture and an unattributed one. `lib/Share.js` owns
the table, next to the naming and the frame window, so the two cannot drift.

## Sharing

The map can be kept. A share is a grab of the map item — `Item.grabToImage`,
which renders the item and its children — so the basemap, the radar frame, the
air overlay, the rings and the credit line are composited by Qt into one PNG.
There is no second map to keep in step with the first and no image library in
the loop. Which is also why the legend has to be a child of the map during an
export: the panel's own strip is a sibling of the map and a grab cannot see
it, and an air-quality image with no scale on it is a picture of a colour
field. So the map grows a second, normally-invisible `LegendStrip` and a veil,
both gated on one `exporting` property, and the progress line lives outside
the map precisely so it is never baked into a frame.

A loop is the radar's own transport, driven one frame at a time instead of by
the playback timer: stage the frame, wait for the swap, wait out the crossfade,
grab. Nothing re-renders the map or re-requests a tile, and the share is paced
by the network rather than by a clock. Only the radar is offered a loop,
because only the radar has a transport — a CAMS forecast is never scrubbed, so
there is no sequence of it to animate, and offering a one-frame GIF would be a
worse answer than the still. Everything a share borrows — the frame index, the
followed time, the transport — is handed back on every path out, including
cancel and failure; a share that left the panel on a different frame than the
user was looking at would be the worst bug in the plugin.

`share.py` is the isolated share helper, in the shape of `cams.py`: three
subcommands, an argv array, an absolute interpreter, stdlib only. A still is a
byte copy, because the grab is already a PNG and the map already draws its own
attribution. A loop is the only encoding in the tree — median cut, a 4-bit
lookup cube, serpentine error diffusion, LZW — and it is a hundred lines of
arithmetic rather than a package this plugin would otherwise not need. The
lookup cube is what makes that affordable: without it every pixel of every
frame would be compared against every palette entry.

Every path the helper writes goes through a directory walk with held
descriptors, an `O_EXCL` temporary, `fsync`, and `rename` — the manual's own
shape, not a new one. A directory it owns is refused rather than repaired when
it is not private, and the refusal names the command that fixes it. It demands
that of `share`, the directory it creates, and not of
`~/.config/omarchy/akash`, which the rest of this plugin created under the
default umask before any share could happen: holding a pre-existing directory
to a mode the plugin itself does not use refuses every share on every install.
Frames are read through the descriptor that was checked. The one boundary this
design does not close is `saveToFile`, which Qt opens by name: the name comes
from `mkdtemp` inside a 700 directory the helper created and then deletes, so
it is the manual's same-UID hardening class rather than a blocker, and it is
written down here rather than left in a comment.

The helper's stderr is collected, not discarded, and becomes the body of the
failure toast. A share that can only report "it did not save" is a support
ticket waiting to happen, and the reason lives on exactly the stream a plugin
is most likely to forget it has claimed. The collector only accumulates; the
text is read where the exit code is known, because `onStreamFinished` fires
first and a refusal read there would look like one that completed.

The name is reduced to `[a-z0-9-]` before it reaches a path, and a CAMS layer
title is remote text. That is why the share notification needs no strip pass:
the sink is safe by construction, and a strip pass over an already-safe string
would be the appearance of a check rather than one.

## Location, onboarding, and map

The map centre comes from exactly one source: Omarchy's shared weather
location, `~/.local/state/omarchy/settings/weather.json`, read read-only and
watched through a `FileView` in the service. There is deliberately no parallel
store: widget settings (the shell.json entry) hold preferences and the
last-used view, and `state.json` holds CAMS session restore, and neither is a
centre. The file Omarchy's weather widget owns is the single source of truth,
so the two widgets agree by construction rather than by reconciliation.

The bar's air-quality probe falls back, when weather.json has no coordinates,
to `state.json`'s `home` — a country-level value from the timezone, better
than none — and then to no reading. A saved location name without coordinates
is its own state, "unresolved", and is reported rather than dropped: the
picker prints "no coordinates — pick one from the list", and the alert
status says "the saved location has no coordinates".

The picker is the stock weather widget's — same geocoding, same
`omarchy-weather-location` CLI. Choosing a city there writes weather.json
through that CLI; the watch re-centres the radar live. The picker also
accepts exact GPS coordinates as an alternative entry: a name plus a lat/lon
pair, typed in the picker's coordinates mode, validated against the same
shape the CLI accepts, and written through the same `--set <name> <lat>,<lon>`
call. A longitude in the 0–360 east convention is normalised onto the globe
(`TileMath.wrapLongitude`) rather than rejected, so a reading of 180.5°E
becomes 179.5°W. A typed point is not a parallel store — it is the same single
location, made sharper, and the stock widget continues to work from it as it
does from a geocoded coordinate. The plugin never writes Omarchy, Hyprland
or system configuration outside its own shell.json entry.

Refresh, and new frame lists arriving while the panel is open, never move the
viewport or reset the camera. The radar timeline remembers the moment the
user was looking at (`lib/Frames.js`), not the index, and re-places it as
the list moves underneath; a CAMS forecast has no scrub position to keep,
and simply re-centres on the step nearest now. Closing preserves the
session: the panel object stays mounted, so the chosen zoom, the last-used
view and the followed time all survive a close. Reopening then starts
"about now" — centred on the location, on the newest frame — because opening
is a question about now; while open, scrubbing and panning are never
disturbed by an arriving frame list.

The ground is decoded once per session and then kept decoded: after the first
decode the arrays are written to `~/.config/omarchy/akash/basemap.cache`, and
the next session reads them back as views over one buffer instead of spending
the better part of a second on the varint pass. The cache is never an
authority. It carries its own layout version and the digest of the ground it
was decoded from, and a missing, truncated, or differently stamped file is
discarded and `data/basemap.bin` decoded as before, so a bad cache costs a
decode rather than a map. `lib/Basemap.js` owns the format; the digest lives in
`lib/BasemapDigest.js`, which `tools/build-basemap.py` regenerates, so a
rebuilt ground invalidates every cached decode by construction — there is no
version to remember to bump in the same commit.

## Split

All network, polling, and alert state lives in `Service.qml`, mounted once per
plugin; a bar widget is instantiated per monitor and a service is not, so
two monitors never double a request. The widget and the panel bind to the
service's summary properties; they poll nothing themselves.

`lib/*.js` are pure functions over plain values, one concern each, pinned by
`node --test`. Anything that is not a pure function does not belong there.

`share.py` is the isolated share helper, and is covered by its own section
above; like `cams.py` it is stdlib-only, it is an argv array, and its parent
directories are walked with held descriptors rather than resolved by name.

The share chooser is a `qs.Ui.ConfirmDialog`, and it lives inside
`ui/KeyboardPanel` with a `z` above the key catcher — the same place the
shell's own dialogs sit. That placement is not cosmetic and not movable: the
keyboard panel is a `PanelWindow`, so a dialog declared at the panel's own
level is in a different window from the map and no `z` can raise it above one,
and inside the window but below the key catcher it opens, paints underneath,
and eats no clicks. Both failures look identical from the outside — a share
button that does nothing.

The dialog's two buttons and its dismissing gestures arrive through two
signals, and the mapping is not the obvious one: `confirmed()` is the right
button, `canceled()` is *both* the left button and a click on the scrim. So
the left option has to be read out of `selectedIndex`, which a button sets to
its own position as it is pressed and the scrim leaves alone — treating
`canceled()` as a dismissal makes "PNG image" close the dialog and share
nothing, which is a dead button that looks merely broken. All three ways in —
the two buttons and Return — go through one function, because three copies of
the if/else is three chances to get that mapping wrong, and it was wrong three
times. Escape is handled by the panel and never routed through the dialog's
own `handleKey`, which emits `canceled()` for it and would save an image nobody
chose.

`cams.py` is the isolated CAMS/network helper: the capabilities cache
(`caps.json`, refreshed at most every 6 hours), the WMS `GetFeatureInfo`
probe, region-from-timezone, and per-endpoint byte ceilings (1 MiB
capabilities, 4 KiB probe) enforced mid-stream. Every process
that reads stdout back into the shell process is bounded the same way, and
`test/streams.test.js` pins each stream and its ceiling. The service points
its readers at `caps.json` and `state.json` at construction, so a cache left
by an earlier session renders the layer chips immediately instead of waiting
on the subprocess — a stale cache is shown until the refresh lands, the same
policy as the radar frames — while the six-hour refresh still runs once per
session.

Deliberate preferences live in the widget's shell.json entry, managed by the
`omarchy` CLI; session restore lives in `~/.config/omarchy/akash/state.json`,
written atomically (temp file, fsync, rename) by cams.py. A setting the code
cannot act on is named rather than silently defaulted: an unrecognised band
name falls back to the default but is reported, and an alert radius outside
the presets is added to the list rather than dropped.

## Scope

Keep the feature set small. Prefer stock integrations — the shared weather
location, `omarchy-weather-location`, `omarchy-notification-send`, the
first-party bar APIs — over parallel mechanisms inside this plugin. If a
visual call is open, change the running picture and look at it.

## Future direction

A Rust engine release binary, sha256-pinned, run as
a daemon the shell talks to — is the right path only if a raw local-decode
data source is ever added: a national high-resolution radar feed, or motion
analysis over frames. Only then does the decode cost justify a compiled
engine that decodes once and serves the shell by IPC. It is not warranted for
the current HTTP-tile sources, which the shell and cams.py already fetch
directly, and it is never to be started now.
