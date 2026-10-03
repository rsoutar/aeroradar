#!/usr/bin/env bash
#
# The share path end to end, under a real QML engine.
#
# Everything else about sharing is arithmetic in share.py, and
# test/share.test.py covers that. What no other test can reach is the one thing
# the design rests on: that `Item.grabToImage` really does render the map *and
# its children*, and that the PNG it writes is a PNG share.py will accept. If
# grabToImage came back empty, or skipped the export legend, every unit test in
# the tree would still pass and the feature would ship broken.
#
# So this runs MapCanvas.qml under Quickshell and grabs itself three times: with
# the export overlay showing, without it, and at twice the size. The first two
# files must differ. That single difference is the whole claim — the grab sees
# the children, and the children include the legend, which is what makes a
# shared air-quality map readable instead of a picture of a colour field.
#
# Then the real `share.py finish` runs over what the grab actually wrote, once
# per mode on its own run directory: a still that is byte-identical to the
# grab, and a GIF carrying a frame for every frame it was given.
#
# HOME is redirected, because share.py writes to ~/Pictures/akash and a test
# suite has no business writing into the developer's home directory.

set -uo pipefail

cd "$(dirname "$0")/.."
plugin=$PWD

if ! command -v qs > /dev/null 2>&1; then
  if [[ -n ${AKASH_REQUIRE_QS:-} ]]; then
    echo "AKASH_REQUIRE_QS is set and there is no qs on PATH" >&2
    exit 1
  fi
  echo "no qs on PATH; skipping (set AKASH_REQUIRE_QS to make this fatal)"
  exit 0
fi

if [[ ! -d /usr/share/omarchy/shell/Commons || ! -d /usr/share/omarchy/shell/Ui ]]; then
  if [[ -n ${AKASH_REQUIRE_QS:-} ]]; then
    echo "AKASH_REQUIRE_QS is set and the Omarchy shell modules are missing" >&2
    exit 1
  fi
  echo "Omarchy shell modules not found; skipping"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/Commons" "$work/Ui" "$work/ui" "$work/lib" "$work/runtime" "$work/home"
cp "$plugin/ui/"*.qml "$work/ui/"
cp "$plugin/lib/"*.js "$work/lib/"
cp "$plugin/share.py" "$work/share.py"
cp /usr/share/omarchy/shell/Commons/* "$work/Commons/"
cp /usr/share/omarchy/shell/Ui/* "$work/Ui/"

py=/usr/bin/python3
share() { HOME="$work/home" "$py" -I -S share.py "$@"; }

# The check/report helpers, defined before the first scenario uses them.
failures=0
check() {
  local label=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then
    printf '  ok    %s\n' "$label"
  else
    printf '  FAIL  %s (expected %s, got %s)\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}
note() { printf '  ok    %s\n' "$1"; }
refuse() { printf '  FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); }
value() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | tail -1; }

# ---- the probe ------------------------------------------------------------
#
# A window holding the map, and a list of grabs to take of it. Each step is
# [frame index, exporting, target width].
#
# The width is not incidental: a loop is only a loop if its frames are the same
# size, and share.py refuses a mixed set rather than rescaling it — so the
# compare run, which deliberately grabs one frame at 2x, has to be a run of its
# own. STEPS is set by each scenario before it calls run_probe.

cat > "$work/probe.tmpl" <<'PROBE'
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ui"

ShellRoot {
  id: harness

  // Two array literals rather than one object: QML reads `property var x: {` as
  // the start of a binding block rather than as a JavaScript object, so the
  // combined form fails to parse with a message about a missing comma.
  property var frames: [__FRAMES__]
  property var steps: [__STEPS__]
  property int at: 0

  function report(key, value) { console.log("PROBE " + key + "=" + value) }
  function failed(why) { report("failed", why); Qt.quit() }

  // grabToImage refuses an item that is not in a window, and a ShellRoot is not
  // one — so the map goes in a Window here for exactly the reason the panel is
  // one: that is where it lives when this is not a test.
  Window {
    visible: true
    width: 240
    height: 160
    color: "black"

    MapCanvas {
      id: map
      anchors.fill: parent
      centerLatitude: 51.5
      centerLongitude: -0.13
      zoom: 5
      attribution: "RainViewer · Natural Earth"
      legendMode: "radar"
    }
  }

  // One grab at a time, with the next armed from the previous one's callback
  // rather than queued beside it. `exporting` is read when the grab is
  // *rendered*, not when it is asked for, so two overlapping grabs would both
  // photograph whatever the property says by the time the scene graph reaches
  // them — and the overlay comparison would then be two identical files for a
  // reason that has nothing to do with overlays.
  function step() {
    if (harness.at >= harness.steps.length) return Qt.quit()
    var s = harness.steps[harness.at]
    map.exporting = s[1]
    map.grabToImage(function(result) {
      if (!result.saveToFile(harness.frames[s[0]])) return harness.failed("saveToFile refused frame " + s[0])
      harness.report("grab-" + s[0], "ok")
      harness.at++
      Qt.callLater(harness.step)
    }, Qt.size(s[2], Math.round(s[2] * 160 / 240)))
  }

  Component.onCompleted: start.restart()

  // The scene graph has to exist before a grab means anything, and it is built
  // on the first rendered frame.
  Timer {
    id: start
    interval: 700
    onTriggered: harness.step()
  }

  // A grab that never comes back is a hang, not a failure the shell reports.
  Timer {
    interval: 30000
    running: true
    onTriggered: harness.failed("a grab never completed")
  }
}
PROBE

# begin N: sets RUNDIR to the run directory's name and FRAMES to its N frame
# paths. bash has no way to return two values without a subshell that loses
# them, so these are globals on purpose.
begin_run() {
  local count=$1
  local named=()
  mapfile -t named < <(share begin "$count")
  if (( ${#named[@]} != count + 1 )); then
    echo "  FAIL  share.py begin $count named ${#named[@]} lines, expected $((count + 1))" >&2
    exit 1
  fi
  RUNDIR=${named[0]##*/}
  FRAMES=("${named[@]:1}")
}

js_string() {
  local f=${1//\\/\\\\}
  printf '"%s"' "${f//\"/\\\"}"
}

# run_probe $@ — indexes into FRAMES, one per step. STEPS is already set.
run_probe() {
  local frames="" i
  for i in "$@"; do
    frames+="$(js_string "${FRAMES[$i]}"),"
  done
  sed -e "s|__FRAMES__|$frames|" -e "s|__STEPS__|$STEPS|" \
      "$work/probe.tmpl" > "$work/probe.qml"
  env -u QT_QPA_PLATFORMTHEME HOME="$work/home" QT_QPA_PLATFORM=offscreen \
      XDG_RUNTIME_DIR="$work/runtime" \
      timeout 90 qs -p "$work/probe.qml" 2>&1 | sed -n 's/.*PROBE //p'
}

# ---- the grab itself, and the two comparisons that make it mean something --

begin_run 3
frames=("${FRAMES[@]}")
STEPS='[0, true, 240], [1, false, 240], [2, true, 480]'
out=$(run_probe 0 1 2)
probe_failed=$(value failed)
if [[ -z "$out" ]]; then
  echo "  FAIL  the probe printed nothing at all" >&2
  exit 1
fi
if [[ -n "$probe_failed" ]]; then
  echo "  FAIL  the probe reported: $probe_failed" >&2
  exit 1
fi
check "the map grabs itself with the export legend"      "ok" "$(value grab-0)"
check "the map grabs itself without the export legend"   "ok" "$(value grab-1)"
check "the map grabs itself at twice the size"          "ok" "$(value grab-2)"

# The claim, in one comparison. Identical files would mean the export legend is
# not inside the grab, which is the one thing that makes a shared air-quality
# map readable instead of a picture of a colour field.
if cmp -s "${frames[0]}" "${frames[1]}"; then
  refuse "the export legend is not in the grab: the two files are identical"
else
  note "the export legend is inside the grab, not beside it"
fi

# A grab that rendered something is a grab. Without this the comparison above
# also passes when the two files are the same empty rectangle.
#
# Measured against a blank PNG of the same dimensions rather than against a byte
# count. A guessed threshold is a false alarm the moment the picture changes:
# removing the progress veil took this from 4194 bytes to 1177, because a flat
# sea colour under a legend compresses to almost nothing, and the threshold
# that said "not blank" was really saying "the veil is still there".
blank=$("$py" -I -S -c '
import struct, sys, zlib
w, h = 240, 160
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
row = b"\x00" + bytes([22, 26, 34]) * w
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(row * h, 9))
       + chunk(b"IEND", b""))
open(sys.argv[1], "wb").write(png)
' "$work/blank.png" && stat -c %s "$work/blank.png")

grabbed=$(stat -c %s "${frames[0]}")
if (( grabbed <= blank )); then
  refuse "the grab is blank or smaller than a blank frame of the same size ($grabbed vs $blank bytes)"
else
  note "the grab is not blank ($grabbed bytes against $blank for a blank frame)"
fi

# targetSize being quietly ignored would mean every still is exported at the
# panel's own size.
small=$(stat -c %s "${frames[1]}")
large=$(stat -c %s "${frames[2]}")
if (( large <= small )); then
  refuse "targetSize is ignored: 2x is $large bytes, 1x is $small"
else
  note "the grab honours targetSize ($small bytes at 1x, $large at 2x)"
fi

# The frames have been read; the run directory has done its job, and whether
# the helper removes it is checked at the end of the run rather than here.
share abort "$RUNDIR" > /dev/null

# ---- a still, from one frame ---------------------------------------------

begin_run 1
still_frame=${FRAMES[0]}
STEPS='[0, true, 480]'
out=$(run_probe 0)
probe_failed=$(value failed)
check "the map grabs itself for a still" "ok" "$(value grab-0)"
if [[ -n "$probe_failed" ]]; then
  echo "  FAIL  the probe reported: $probe_failed" >&2
  exit 1
fi
# Kept aside before `finish`, because `finish` removes the run directory on its
# way out and the file being compared is in it. Comparing a file that the
# helper has already deleted would report a difference that is not one.
cp "$still_frame" "$work/grab.png"

# "path<TAB>bytes": the path is the file, and the count is the check that
# something came back at all.
answer=$(share finish "$RUNDIR" image akash-radar-20260926-1430)
still=${answer%%$'\t'*}
still_bytes=${answer##*$'\t'}
check "a still share names a .png" "png" "${still##*.}"
check "the still is the size of a map" "true" \
  "$([[ $still_bytes -gt 2000 ]] && echo true || echo false)"
if cmp -s "$work/grab.png" "$still"; then
  note "the still is the grab, byte for byte"
else
  refuse "the still is not the grab it was made from ($(stat -c %s "$work/grab.png") vs $(stat -c %s "$still") bytes)"
fi

# ---- a loop, from three frames of one size --------------------------------

begin_run 3
frames=("${FRAMES[@]}")
STEPS='[0, true, 240], [1, true, 240], [2, true, 240]'
run_probe 0 1 2 > /dev/null

answer=$(share finish "$RUNDIR" gif akash-radar-20260926-1431)
gif=${answer%%$'\t'*}
check "a loop share names a .gif" "gif" "${gif##*.}"

# A GIF carrying fewer frames than it was given will not animate, and the
# header alone would not show that.
frames_in_gif=$("$py" -I -S -c '
import sys
data = open(sys.argv[1], "rb").read()
print("not-a-gif" if data[:6] != b"GIF89a" else data.count(b"\x21\xf9\x04"))
' "$gif")
check "the loop carries a frame for every frame captured" "3" "$frames_in_gif"

# A share directory that accumulates is several megabytes of somebody's weather
# per export, and nothing ever prunes it.
leftover=$(find "$work/home/.config/omarchy/akash/share" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
check "no run directory is left behind" "0" "$leftover"

echo
if (( failures > 0 )); then
  echo "share qml: $failures check(s) failed"
  exit 1
fi
echo "share qml: all checks passed"
