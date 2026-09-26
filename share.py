#!/usr/bin/python3 -I
"""The share helper: turn a grab of the map into a file the user can keep.

The panel grabs its own map with ``Item.grabToImage`` and hands the PNGs here.
Qt has already composited the basemap, the radar frames, the legend and the
credit line into each one, so there is nothing to draw and nothing to resize
here. What is left is three jobs, and only the third is real work:

  ``begin``   make a private run directory and name the frame files
  ``finish``  read those frames back and write the file the user asked for
  ``abort``   remove the run directory

``finish image`` is a byte copy, because the grab is already a PNG and the map
already draws its own attribution. ``finish gif`` is the only encoding in the
tree: decode each frame, build one global palette, and LZW the indices.

Everything is stdlib. A GIF encoder is a hundred lines of arithmetic and a
new dependency is a hundred lines of somebody else's arithmetic plus a
package this plugin would otherwise not need.

Invoked as an argv array from ``BoundedProcess``::

    ["/usr/bin/python3", "-I", "-S", pluginDir + "/share.py", "finish", ...]

No shell, no interpolation, and the only things that arrive on argv are a mode,
a run directory name and a file stem the panel built from ``lib/Share.js``.
"""

import os
import re
import secrets
import stat
import struct
import sys
import zlib

# ---------------------------------------------------------------------------
# Limits
#
# Every one of these is a ceiling the code enforces, not a comment. They are
# numbers rather than expressions because the point is that they are small
# enough to hold in the head, and the test pins them.
# ---------------------------------------------------------------------------

# A grab of the map at 2x. The panel passes a targetSize it has already
# clamped; this is the second, independent bound, because the argument crosses
# a process boundary and a caller is not to be trusted with an allocation.
MAX_FRAME_BYTES = 4 * 1024 * 1024
MAX_FRAME_PIXELS = 4 * 1024 * 1024
MAX_FRAMES = 16

# The encoded GIF. Eight frames of a dark map at 1x lands well under this; the
# ceiling exists so a pathological palette cannot fill the home directory.
MAX_OUTPUT_BYTES = 24 * 1024 * 1024

# A third of a second a frame. RainViewer publishes ten minutes apart, so real
# time is not an option, and half a second reads as a slideshow. Kept here
# rather than taken from the panel so the number the bytes carry is the number
# the panel's own delay says it is.
FRAME_DELAY_CS = 30

# stdout is a path and a byte count. Nothing else comes back, ever.
MAX_STDOUT_BYTES = 4096

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"

# A single path component. Dots are allowed because `~/.local` and `~/.config`
# are what they are; `.` and `..` are refused by name, since a component that
# is one of those two is the only way to walk out of the directory this opened
# and a pattern that permits them as a side effect is not a check.
COMPONENT = re.compile(r"\A[A-Za-z0-9_.-]{1,64}\Z")

# A file stem from lib/Share.js. Stricter than a directory component because
# this one is what the user ends up looking at, and `slug` leaves only this
# alphabet in it. A leading dash cannot reach it either, so nothing here can
# be read as an option.
FILE_STEM = re.compile(r"\A[a-z0-9][a-z0-9-]{0,63}\Z")


def is_component(name):
    return isinstance(name, str) and name not in (".", "..") and COMPONENT.match(name) is not None


class ShareError(Exception):
    """Anything the panel should see as a failed share, not a traceback."""


# ---------------------------------------------------------------------------
# The filesystem
#
# The manual's own shape: walk the parents with held descriptors, create what
# is missing, and do every later open relative to the descriptor rather than
# to a name. A path is resolved once, here, and after this point the plugin
# only ever holds a descriptor.
# ---------------------------------------------------------------------------


def open_dir_chain(parts, private_from=None):
    """Open a directory by walking down from the passwd home with dirfds.

    ``private_from`` is the index at which the plugin's own subtree starts.
    Components below it are created 0700 and required to be 0700; components
    above it are only checked for being a real directory this user owns,
    because they are Omarchy's or the user's and their mode is not ours to
    change. ``~/Pictures`` is a user's folder, and tightening it to 0700 to
    satisfy a rule about our own state directory would be the plugin editing
    something it does not own.
    """
    home = os.path.expanduser("~")
    try:
        fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as why:
        raise ShareError("cannot open the home directory: %s" % why)

    try:
        for index, name in enumerate(parts):
            ours = private_from is not None and index >= private_from
            if not is_component(name):
                raise ShareError("refusing the path component %r" % name)
            try:
                nfd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            except FileNotFoundError:
                os.mkdir(name, 0o700, dir_fd=fd)
                nfd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            except OSError as why:
                # A symlink where a directory belongs is ENOTDIR under
                # O_NOFOLLOW, not ELOOP. At this point the message is the whole
                # report: the panel shows stderr verbatim, and "Traceback" is
                # not a sentence anyone can act on.
                raise ShareError("refusing the directory %r: %s" % (name, why.strerror or why))
            os.close(fd)
            fd = nfd

            info = os.fstat(fd)
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
                raise ShareError("refusing the directory %r" % name)
            if ours and stat.S_IMODE(info.st_mode) != 0o700:
                # Refuse rather than repair: a directory that was ever wider
                # may hold entries this plugin did not put there. The mode is
                # reported with the command that fixes it, because a share that
                # fails for a reason it will not say is a support ticket.
                raise ShareError(
                    "%s under your home is %o, not 700 — run: chmod 700 %s"
                    % (name, stat.S_IMODE(info.st_mode), name))
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_bounded(dirfd, name, ceiling):
    """Read a regular file we own, through one descriptor, refusing overflow.

    The descriptor that was checked is the descriptor that was read, and the
    bytes come back rather than a path, so nothing downstream re-resolves the
    name.
    """
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=dirfd)
    except FileNotFoundError:
        raise ShareError("the frame %s is missing" % name)
    except OSError as why:
        # A symlink here is ELOOP, not ENOENT, and letting it out as an OSError
        # means a traceback instead of the sentence saying what was wrong.
        raise ShareError("refusing the frame %s: %s" % (name, why.strerror or why))

    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
            raise ShareError("refusing the frame %s: not our own regular file" % name)
        if info.st_size > ceiling:
            raise ShareError("the frame %s is %d bytes, over the %d ceiling" % (name, info.st_size, ceiling))

        # O_NONBLOCK was there to make a planted FIFO fail open instead of
        # hanging the shell; a real file is not a pipe, so blocking is safe
        # again and has to be restored before reading it.
        os.set_blocking(fd, True)
        data = b""
        while len(data) <= ceiling:
            chunk = os.read(fd, min(65536, ceiling + 1 - len(data)))
            if not chunk:
                break
            data += chunk
        if len(data) > ceiling:
            raise ShareError("the frame %s grew past the ceiling" % name)
        return data
    finally:
        os.close(fd)


def write_atomic(dirfd, name, data):
    """Publish bytes to a name, through one descriptor, atomically.

    ``rename`` replaces whatever is at the destination rather than writing
    through it, so a symlink planted at the name costs the symlink and not its
    target. The temporary is created with O_EXCL beside the destination, so
    there is no window in which its name is predictable.
    """
    temporary = ".%s.%s.tmp" % (name, secrets.token_hex(8))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=dirfd)
    try:
        os.fchmod(fd, 0o600)
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
        os.rename(temporary, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
        os.fsync(dirfd)
    except BaseException:
        try:
            os.unlink(temporary, dir_fd=dirfd)
        except OSError:
            pass
        raise
    finally:
        os.close(fd)


def free_name(dirfd, stem, extension):
    """A name in this directory that nothing occupies.

    Checked and claimed through the held descriptor, and the check is
    advisory: the create that follows is O_EXCL either way, so a file that
    appears in between costs a retry rather than an overwrite.
    """
    for attempt in range(100):
        name = "%s%s" % (stem, "" if attempt == 0 else "-%d" % (attempt + 1)) + extension
        try:
            os.stat(name, dir_fd=dirfd, follow_symlinks=False)
        except FileNotFoundError:
            return name
    raise ShareError("could not find a free name for %s" % stem)


def remove_run_dir(parts, name):
    """Delete a run directory and the frames this plugin put in it.

    Returns whether it is gone. It never raises: this runs in a `finally` on
    the failure path too, and a cleanup error raised from there replaces the
    error that actually explains what went wrong.

    An entry is only unlinked if it is a regular file, ours, with a single
    link. A run directory is made by mkdtemp inside a 0700 parent, so anything
    else in one was planted — and the answer to a planted file is to leave it
    where it is, not to delete a name this plugin did not create. The directory
    then stays too, empty except for what was put there, and the next share
    makes a new one.
    """
    try:
        share_fd = open_dir_chain(parts, private_from=len(parts) - 1)
    except (ShareError, OSError):
        return False
    try:
        try:
            run_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=share_fd)
        except OSError:
            return False
        try:
            for entry in os.listdir(run_fd):
                try:
                    info = os.stat(entry, dir_fd=run_fd, follow_symlinks=False)
                    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
                        continue
                    os.unlink(entry, dir_fd=run_fd)
                except OSError:
                    pass
            os.rmdir(name, dir_fd=share_fd)
            os.fsync(share_fd)
        except OSError:
            return False
        return True
    finally:
        os.close(share_fd)


# ---------------------------------------------------------------------------
# PNG
#
# Only what Qt's grab writes: 8-bit, non-interlaced, truecolour with or
# without alpha. Anything else is refused by name rather than half-decoded.
# ---------------------------------------------------------------------------


def paeth(a, b, c):
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def unfilter(raw, width, height, bpp):
    stride = width * bpp
    if len(raw) < height * (stride + 1):
        raise ShareError("the frame's image data is short")
    out = bytearray(stride * height)
    position = 0
    previous = bytearray(stride)
    for y in range(height):
        kind = raw[position]
        position += 1
        line = bytearray(raw[position:position + stride])
        position += stride
        if kind == 0:
            pass
        elif kind == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif kind == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif kind == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif kind == 4:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                upper_left = previous[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + paeth(left, previous[i], upper_left)) & 0xFF
        else:
            raise ShareError("the frame uses PNG filter %d" % kind)
        out[y * stride:(y + 1) * stride] = line
        previous = line
    return bytes(out)


def drop_alpha(width, height, pixels):
    """RGBA to RGB, without a Python loop per pixel.

    Three extended slices over the same source and three over the destination:
    the whole conversion is six C-level copies, which matters because this
    runs over every frame of a GIF.
    """
    count = width * height
    out = bytearray(count * 3)
    out[0::3] = pixels[0::4]
    out[1::3] = pixels[1::4]
    out[2::3] = pixels[2::4]
    return bytes(out)


def decode_png(data):
    """A grabbed PNG to (width, height, RGB bytes)."""
    if data[:8] != PNG_MAGIC:
        raise ShareError("that frame is not a PNG")

    position = 8
    width = height = depth = colour = interlace = 0
    idat = []
    while position + 8 <= len(data):
        length = struct.unpack(">I", data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        start = position + 8
        end = start + length
        if end + 4 > len(data):
            raise ShareError("the frame's PNG is truncated")
        if kind == b"IHDR":
            width, height, depth, colour, _compression, _filter, interlace = struct.unpack(">IIBBBBB", data[start:end])
        elif kind == b"IDAT":
            idat.append(data[start:end])
        elif kind == b"IEND":
            break
        position = end + 4

    if depth != 8 or colour not in (2, 6):
        raise ShareError("the frame is a %d-bit PNG of colour type %d; only 8-bit RGB and RGBA are read"
                         % (depth, colour))
    if interlace:
        raise ShareError("the frame is an interlaced PNG")
    if width <= 0 or height <= 0 or width * height > MAX_FRAME_PIXELS:
        raise ShareError("the frame is %dx%d, outside the export ceiling" % (width, height))

    channels = 3 if colour == 2 else 4
    pixels = unfilter(zlib.decompress(b"".join(idat)), width, height, channels)
    if channels == 4:
        pixels = drop_alpha(width, height, pixels)
    return width, height, pixels


# ---------------------------------------------------------------------------
# Palette
#
# Median cut, then a lookup cube. The cube is the part that makes this
# practical: without it every pixel of every frame would be compared against
# every palette entry, which in Python is a hundred and seventy million
# operations for one frame.
# ---------------------------------------------------------------------------

PALETTE_MAX = 256
SAMPLE_MAX = 16384
CUBE_BITS = 4
CUBE_SIZE = 1 << (3 * CUBE_BITS)
CUBE_STEP = 255 // ((1 << CUBE_BITS) - 1)


def bounds(colours):
    return tuple((min(c[axis] for c in colours), max(c[axis] for c in colours)) for axis in range(3))


def average(colours):
    count = len(colours)
    return tuple(sum(c[axis] for c in colours) // count for axis in range(3))


def sample(pixels, width, height):
    """The distinct colours in a frame, up to about SAMPLE_MAX of them.

    Distinct, not merely spread out. A median cut over a list that holds the
    same colour ten thousand times will happily spend its whole budget splitting
    that one colour in half: three colours in the picture come back as two
    hundred and fifty-six palette entries, two hundred and fifty-three of which
    are duplicates, and a GIF colour table of the same.
    """
    total = width * height
    step = max(1, total // SAMPLE_MAX)
    seen = {}
    for i in range(0, total, step):
        seen[(pixels[i * 3], pixels[i * 3 + 1], pixels[i * 3 + 2])] = None
        if len(seen) >= SAMPLE_MAX:
            break
    return list(seen)


def median_cut(samples, wanted):
    """Up to `wanted` colours, by repeatedly halving the fullest box.

    The bounds of a box are computed once, when the box is made, and carried
    beside it. Recomputing them to choose the next split would be a pass over
    the samples per candidate per iteration, which is the difference between
    this finishing in a moment and this finishing in a coffee break.
    """
    if not samples:
        return [(0, 0, 0)]

    boxes = [(samples, bounds(samples))]
    while len(boxes) < wanted:
        best = -1
        best_score = -1
        for index, (box, box_bounds) in enumerate(boxes):
            if len(box) < 2:
                continue
            score = len(box)
            for low, high in box_bounds:
                score *= high - low + 1
            if score > best_score:
                best_score = score
                best = index
        if best < 0:
            break

        box, box_bounds = boxes.pop(best)
        axis = max(range(3), key=lambda a: box_bounds[a][1] - box_bounds[a][0])
        box.sort(key=lambda colour: colour[axis])
        cut = len(box) // 2
        for half in (box[:cut], box[cut:]):
            boxes.append((half, bounds(half)))

    return [average(box) for box, _ in boxes]


def build_cube(palette):
    """For each cell of a 4-bit-per-channel cube, the nearest palette index.

    Sixteen levels a channel is a coarser grid than the palette deserves, but
    the error that leaves is a fraction of a level, and Floyd-Steinberg spends
    the rest of the budget hiding it.
    """
    flat = [(r, g, b) for r, g, b in palette]
    cube = bytearray(CUBE_SIZE)
    limit = len(flat)
    for r4 in range(1 << CUBE_BITS):
        r = r4 * CUBE_STEP
        for g4 in range(1 << CUBE_BITS):
            g = g4 * CUBE_STEP
            base = (r4 << (2 * CUBE_BITS)) | (g4 << CUBE_BITS)
            for b4 in range(1 << CUBE_BITS):
                b = b4 * CUBE_STEP
                best = 0
                best_distance = 1 << 30
                for index in range(limit):
                    pr, pg, pb = flat[index]
                    dr = r - pr
                    dg = g - pg
                    db = b - pb
                    distance = dr * dr + dg * dg + db * db
                    if distance < best_distance:
                        best_distance = distance
                        best = index
                cube[base | b4] = best
    return cube


def quantise(width, height, pixels, cube, palette):
    """Indices for one frame, with serpentine error diffusion.

    Serpentine rather than left-to-right: the scan reverses every other row, so
    the drift that one-dimensional diffusion would carry off the right-hand
    edge of a row is handed back at the start of the next one. That is what
    keeps a one-dimensional pass from drawing worms across a smooth sky.
    """
    out = bytearray(width * height)
    for y in range(height):
        base = y * width
        if y % 2 == 0:
            walk = range(base, base + width)
        else:
            walk = range(base + width - 1, base - 1, -1)
        carry_r = carry_g = carry_b = 0.0
        for i in walk:
            p = i * 3
            r = pixels[p] + carry_r
            g = pixels[p + 1] + carry_g
            b = pixels[p + 2] + carry_b
            r = 0 if r < 0 else (255 if r > 255 else int(r))
            g = 0 if g < 0 else (255 if g > 255 else int(g))
            b = 0 if b < 0 else (255 if b > 255 else int(b))
            index = cube[((r >> (8 - CUBE_BITS)) << (2 * CUBE_BITS))
                         | ((g >> (8 - CUBE_BITS)) << CUBE_BITS)
                         | (b >> (8 - CUBE_BITS))]
            out[i] = index
            pr, pg, pb = palette[index]
            carry_r = r - pr
            carry_g = g - pg
            carry_b = b - pb
    return out


# ---------------------------------------------------------------------------
# GIF89a
# ---------------------------------------------------------------------------


def lzw(indices, minimum):
    """GIF-flavoured LZW: variable width, LSB-first, cleared when full."""
    clear = 1 << minimum
    end = clear + 1
    width = minimum + 1
    nxt = end + 1
    table = {}
    out = bytearray()
    buffer = 0
    bits = 0

    def emit(code):
        nonlocal buffer, bits
        buffer |= code << bits
        bits += width
        while bits >= 8:
            out.append(buffer & 0xFF)
            buffer >>= 8
            bits -= 8

    emit(clear)
    if indices:
        prefix = indices[0]
        for value in indices[1:]:
            found = table.get((prefix, value))
            if found is not None:
                prefix = found
                continue
            emit(prefix)
            if nxt < 4096:
                table[(prefix, value)] = nxt
                nxt += 1
                # The width grows when the next code to hand out needs a bit
                # more than the current width holds — which is `nxt` passing
                # `1 << width`, not reaching it. The decoder builds its table
                # one entry behind this one, so it crosses the line a code
                # earlier; matching it here is what keeps the two reading the
                # same widths. Gating on `nxt == 1 << width` produces a file
                # whose header every tool pings happily and whose pixels
                # nothing can decode.
                if nxt > (1 << width) and width < 12:
                    width += 1
            else:
                # The table is full. A clear is the only way to keep emitting
                # codes, and the decoder drops everything it had.
                emit(clear)
                table = {}
                nxt = end + 1
                width = minimum + 1
            prefix = value
        emit(prefix)
    emit(end)
    if bits:
        out.append(buffer & 0xFF)
    return bytes(out)


def block(data):
    """GIF sub-blocks: at most 255 bytes each, terminated by a zero length."""
    out = bytearray()
    for start in range(0, len(data), 255):
        piece = data[start:start + 255]
        out.append(len(piece))
        out += piece
    out.append(0)
    return bytes(out)


def build_gif(frames, palette, delay_cs):
    """frames: a list of (width, height, index bytes). One loop, no disposal."""
    width, height = frames[0][0], frames[0][1]

    table_size = 2
    while table_size < len(palette):
        table_size <<= 1
    table_size = max(table_size, 2)
    minimum = max(2, table_size.bit_length() - 1)
    padded = list(palette) + [(0, 0, 0)] * (table_size - len(palette))

    out = bytearray(b"GIF89a")
    out += struct.pack("<HH", width, height)
    # The logical screen's packed byte: bit 7 says a global colour table
    # follows, bits 6-4 are the colour resolution, bit 3 the sort flag, and
    # the low three are log2(table) - 1. Missing the 0x80 produces a file that
    # looks right to `head` and is read as a 256-colour table by nothing.
    out += bytes((0x80 | 0x70 | (table_size.bit_length() - 2), 0, 0))
    for r, g, b in padded:
        out += bytes((r, g, b))

    # Loop forever, as every animated GIF on the internet does.
    out += b"\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00"

    for frame_width, frame_height, indices in frames:
        if (frame_width, frame_height) != (width, height):
            raise ShareError("the frames are not all the same size")
        out += b"\x21\xF9\x04" + bytes((0x04, delay_cs & 0xFF, (delay_cs >> 8) & 0xFF, 0, 0))
        out += b"\x2C" + struct.pack("<HHHH", 0, 0, frame_width, frame_height) + bytes((0,))
        out += bytes((minimum,)) + block(lzw(indices, minimum))

    out += b"\x3B"
    return bytes(out)


# ---------------------------------------------------------------------------
# The subcommands
# ---------------------------------------------------------------------------

# The plugin's own directory, and one directory inside it for a share in
# progress. Not ~/.local/state: the plugin already keeps its CAMS state and
# its decoded basemap under ~/.config/omarchy/akash, and a second tree for the
# same plugin means two directories in the removal instructions and two places
# to forget.
#
# Only `share` is required to be private. `~/.config/omarchy/akash` is not: the
# plugin's existing code creates it long before a share ever happens, under the
# default umask, so demanding 700 of it would refuse every share on every
# install that has ever run cams.py. The frames are the user's own weather
# rather than a credential, the directory that holds them is 700, and the file
# that finally gets published is 600 — which is the right amount of private for
# this and does not mean tightening a directory the rest of the plugin does not
# treat as private either.
STATE_PARTS = [".config", "omarchy", "akash", "share"]
OUTPUT_PARTS = ["Pictures", "akash"]


def say(*lines):
    text = "\n".join(lines) + "\n"
    if len(text) > MAX_STDOUT_BYTES:
        raise ShareError("the answer would be longer than the ceiling")
    sys.stdout.write(text)


def begin(count):
    if not 1 <= count <= MAX_FRAMES:
        raise ShareError("a share is between 1 and %d frames" % MAX_FRAMES)
    share_fd = open_dir_chain(STATE_PARTS, private_from=len(STATE_PARTS) - 1)
    try:
        name = ".run-%d-%s" % (os.getpid(), secrets.token_hex(6))
        os.mkdir(name, 0o700, dir_fd=share_fd)
        os.fsync(share_fd)
    finally:
        os.close(share_fd)
    # The run directory first, then one absolute path per frame. Both are
    # absolute because the panel hands the frame paths straight to
    # QQuickItemGrabResult::saveToFile, and a caller that assembles a pathname
    # is how a symlink gets followed. The run directory comes back as its own
    # line rather than something the panel slices out of a frame path, for the
    # same reason.
    base = "/".join([os.path.expanduser("~")] + STATE_PARTS + [name])
    say(base, *["%s/frame-%02d.png" % (base, i) for i in range(count)])


def open_run_dir(parts, name):
    """The run directory as a descriptor, reached without trusting the name."""
    if not is_component(name):
        raise ShareError("refusing the run directory name %r" % name)
    parent = open_dir_chain(parts, private_from=len(parts) - 1)
    try:
        try:
            return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
        except OSError:
            raise ShareError("that share is no longer open")
    finally:
        os.close(parent)


def finish(run, mode, stem):
    """Encode the run, publish the file, and take the run directory with us.

    The cleanup is in a finally rather than at the end, because the interesting
    case is the one that raises. A run directory that survives a failed share is
    eight megabytes of somebody's weather map in a state directory that nothing
    ever prunes, and the next share would sit beside it.
    """
    if not is_component(run):
        raise ShareError("refusing the run directory name %r" % run)
    if mode not in ("image", "gif"):
        raise ShareError("%r is not a share mode" % mode)
    if not FILE_STEM.match(stem):
        raise ShareError("refusing the file name %r" % stem)
    try:
        _encode(run, mode, stem)
    finally:
        remove_run_dir(STATE_PARTS, run)


def _encode(run, mode, stem):
    run_fd = open_run_dir(STATE_PARTS, run)
    try:
        names = sorted(entry for entry in os.listdir(run_fd)
                       if re.fullmatch(r"frame-[0-9]{2}\.png", entry))
        if not names:
            raise ShareError("that share captured no frames")

        if mode == "image":
            if len(names) != 1:
                raise ShareError("a still share expects one frame, found %d" % len(names))
            payload = read_bounded(run_fd, names[0], MAX_FRAME_BYTES)
            if payload[:8] != PNG_MAGIC:
                raise ShareError("that frame is not a PNG")
            extension = ".png"
        else:
            # One palette for the whole animation, the way a real encoder
            # works: a per-frame table would dither each frame against its own
            # colours and the loop would pulse. So the first frame is sampled
            # for the palette, and every frame is then mapped through the one
            # cube built from it.
            decoded = [decode_png(read_bounded(run_fd, name, MAX_FRAME_BYTES)) for name in names]
            size = (decoded[0][0], decoded[0][1])
            for width, height, _ in decoded:
                if (width, height) != size:
                    raise ShareError("the frames are not all the same size")

            palette = median_cut(sample(decoded[0][2], size[0], size[1]), PALETTE_MAX)
            while len(palette) < 2:
                palette.append((0, 0, 0))
            cube = build_cube(palette)
            frames = [(width, height, quantise(width, height, pixels, cube, palette))
                      for width, height, pixels in decoded]
            payload = build_gif(frames, palette, FRAME_DELAY_CS)
            extension = ".gif"

        if len(payload) > MAX_OUTPUT_BYTES:
            raise ShareError("the share came to %d bytes, over the %d ceiling" % (len(payload), MAX_OUTPUT_BYTES))
    finally:
        os.close(run_fd)

    pictures_fd = open_dir_chain(OUTPUT_PARTS, private_from=1)
    try:
        name = free_name(pictures_fd, stem, extension)
        write_atomic(pictures_fd, name, payload)
    finally:
        os.close(pictures_fd)

    say("%s/%s\t%d" % (os.path.expanduser("~"), "/".join(OUTPUT_PARTS + [name]), len(payload)))


def abort(run):
    if not is_component(run):
        raise ShareError("refusing the run directory name %r" % run)
    remove_run_dir(STATE_PARTS, run)
    say("aborted")


def main(argv):
    if len(argv) < 2:
        raise ShareError("usage: share.py begin N | finish RUN MODE STEM | abort RUN")
    action = argv[0]

    if action == "begin":
        if len(argv) != 2:
            raise ShareError("usage: share.py begin N")
        begin(int(argv[1]))
    elif action == "finish":
        if len(argv) != 4:
            raise ShareError("usage: share.py finish RUN MODE STEM")
        finish(argv[1], argv[2], argv[3])
    elif action == "abort":
        if len(argv) != 2:
            raise ShareError("usage: share.py abort RUN")
        abort(argv[1])
    else:
        raise ShareError("%r is not something share.py does" % action)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except ShareError as why:
        sys.stderr.write("akash: %s\n" % why)
        sys.exit(1)
    except (OSError, ValueError) as why:
        # The backstop. Anything the operating system refuses is reported as
        # the sentence it already carries; a traceback out of here is a stack of
        # this file's internals in a panel that has nowhere to put it.
        sys.stderr.write("akash: %s\n" % (getattr(why, "strerror", None) or why))
        sys.exit(1)
