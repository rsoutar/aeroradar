#!/usr/bin/env python3
"""Offline checks for share.py: the codec, and the refusals.

Two things are worth testing here and nothing else. The encoder, because a GIF
that no decoder can read looks exactly like a GIF that can until someone tries
to post it. And the refusals, because every one of them is a decision about a
file the plugin did not write, and a decision that quietly stopped being made
would not change any output — only whose.

The QML half of a share — that the map grabs itself and the grab contains the
export legend — is in test/share.qml-test.sh, because it needs a scene graph.
What is here is everything below that line.

    python3 test/share.test.py
"""

from __future__ import annotations

import importlib.util
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

TEST_ROOT = Path(__file__).resolve().parent
PLUGIN = TEST_ROOT.parent
sys.path.insert(0, str(PLUGIN))

spec = importlib.util.spec_from_file_location("share", PLUGIN / "share.py")
share = importlib.util.module_from_spec(spec)
sys.modules["share"] = spec.loader.exec_module(share) or share


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def chunk(kind: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))


def png_bytes(width: int, height: int, rgb: bytes, colour: int = 2, filt: int = 0) -> bytes:
    """A PNG, the way Qt writes one: 8-bit, not interlaced, filter 0 or 2."""
    channels = 3 if colour == 2 else 4
    stride = width * channels
    raw = bytearray()
    previous = bytes(stride)
    for y in range(height):
        line = rgb[y * stride:(y + 1) * stride]
        if filt == 0:
            raw.append(0)
            raw += line
        elif filt == 2:
            # Up-filtered, so Filt(x) = Raw(x) - Recon(a). Adding here instead
            # produces a file that decodes to a smear, which is the sort of bug
            # that looks like the encoder's fault.
            raw.append(2)
            raw += bytes((line[i] - previous[i]) & 0xFF for i in range(stride))
        else:
            raise AssertionError("the fixture does not write filter %d" % filt)
        previous = line

    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, colour, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    out += chunk(b"IEND", b"")
    return out


def ramp(width: int, height: int, seed: int = 0) -> bytes:
    """A picture with more colours than a small palette can hold exactly."""
    out = bytearray(width * height * 3)
    for y in range(height):
        for x in range(width):
            i = (y * width + x) * 3
            out[i] = (x * 3 + seed) % 256
            out[i + 1] = (y * 5 + seed * 2) % 256
            out[i + 2] = ((x + y) * 2) % 256
    return bytes(out)


# ---------------------------------------------------------------------------
# A decoder, so "the encoder wrote something" is not the same claim as "the
# encoder wrote something a GIF reader can read".
#
# Written against the specification rather than against the encoder, and
# deliberately using a different width rule: the decoder crosses the code-size
# boundary one entry *earlier* than the encoder, because it builds its table
# one code behind. Pinning the decoder to the encoder's rule would have made
# this test agree with a broken encoder.
# ---------------------------------------------------------------------------


def gif_blocks(data: bytes, pos: int):
    out = bytearray()
    while data[pos]:
        n = data[pos]
        out += data[pos + 1:pos + 1 + n]
        pos += n + 1
    return bytes(out), pos + 1


def gif_frames(data: bytes):
    assert data[:6] == b"GIF89a", data[:6]
    width, height, packed, _, _ = struct.unpack("<HHBBB", data[6:13])
    table = []
    if packed & 0x80:
        count = 2 << (packed & 7)
        table = [(data[13 + 3 * i], data[14 + 3 * i], data[15 + 3 * i])
                 for i in range(count)]

    pos = 13 + (count * 3 if packed & 0x80 else 0)
    frames, loops, delay = [], None, None
    while pos < len(data):
        kind = data[pos]
        if kind == 0x3B:
            break
        if kind == 0x21:
            label = data[pos + 1]
            payload, pos = gif_blocks(data, pos + 2)
            if label == 0xF9:
                delay = payload[1] | (payload[2] << 8)
            elif label == 0xFF and payload[:11] == b"NETSCAPE2.0":
                loops = payload[12] | (payload[13] << 8)
            continue
        assert kind == 0x2C, "unexpected block 0x%02x" % kind
        fw, fh = struct.unpack("<HH", data[pos + 5:pos + 9])
        pos += 10
        minimum = data[pos]
        pos += 1
        payload, pos = gif_blocks(data, pos)
        frames.append((fw, fh, minimum, decode_lzw(payload, minimum)))
    return (width, height), table, frames, loops, delay


def decode_lzw(data: bytes, minimum: int) -> bytes:
    clear, end = 1 << minimum, (1 << minimum) + 1
    table = {i: bytes([i]) for i in range(clear)}
    nxt = end + 1
    width = minimum + 1
    bit = 0
    out = bytearray()
    previous = None

    def read(n: int) -> int:
        nonlocal bit
        value = 0
        for k in range(n):
            value |= ((data[bit >> 3] >> (bit & 7)) & 1) << k
            bit += 1
        return value

    while True:
        code = read(width)
        if code == clear:
            table = {i: bytes([i]) for i in range(clear)}
            nxt, width, previous = end + 1, minimum + 1, None
            continue
        if code == end:
            return bytes(out)
        if code in table:
            entry = table[code]
        else:
            assert previous is not None, "the stream starts with a code that is not a colour"
            entry = previous + previous[:1]
        out += entry
        if previous is not None:
            table[nxt] = previous + entry[:1]
            nxt += 1
            # The decoder's rule, and not the encoder's: it gains its entry one
            # code later than the encoder did, so it crosses the boundary one
            # code earlier.
            if nxt > (1 << width) - 1 and width < 12:
                width += 1
        previous = entry


def encode(width: int, height: int, count: int, seed: int = 0) -> bytes:
    decoded = [share.decode_png(png_bytes(width, height, ramp(width, height, seed + k)))
               for k in range(count)]
    palette = share.median_cut(share.sample(decoded[0][2], width, height), share.PALETTE_MAX)
    while len(palette) < 2:
        palette.append((0, 0, 0))
    cube = share.build_cube(palette)
    frames = [(w, h, share.quantise(w, h, px, cube, palette)) for w, h, px in decoded]
    return share.build_gif(frames, palette, share.FRAME_DELAY_CS), palette, frames


# ---------------------------------------------------------------------------
# The codec
# ---------------------------------------------------------------------------


class DecodePng(unittest.TestCase):
    def test_both_filter_types_round_trip(self):
        # Qt picks the filter per row, and the grab is not going to choose
        # always the same one. Filter 2 is the one that depends on the row
        # above, so it is the one that can be wrong on its own.
        source = ramp(23, 17)
        for filt in (0, 2):
            with self.subTest(filter=filt):
                width, height, pixels = share.decode_png(png_bytes(23, 17, source, filt=filt))
                self.assertEqual((width, height), (23, 17))
                self.assertEqual(pixels, source)

    def test_alpha_is_dropped_rather_than_read_as_a_channel(self):
        # Four bytes in, three out. Reading the alpha channel as a fourth
        # colour would shift every pixel by one and produce a plausible-looking
        # picture in the wrong colours.
        width, height, pixels = share.decode_png(
            png_bytes(4, 2, bytes(4 * 2 * 4), colour=6))
        self.assertEqual((width, height), (4, 2))
        self.assertEqual(len(pixels), width * height * 3)

    def test_a_palette_png_is_refused_by_name(self):
        # Not silently mangled into something that looks like a map. Half-read
        # is how a share ends up a grey rectangle with no explanation.
        out = b"\x89PNG\r\n\x1a\n"
        out += chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 3, 0, 0, 0))
        out += chunk(b"IDAT", zlib.compress(b"\0" * 7)) + chunk(b"IEND", b"")
        with self.assertRaises(share.ShareError) as caught:
            share.decode_png(out)
        self.assertIn("colour type 3", str(caught.exception))

    def test_sixteen_bit_is_refused_by_name(self):
        out = b"\x89PNG\r\n\x1a\n"
        out += chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 16, 2, 0, 0, 0))
        out += chunk(b"IDAT", zlib.compress(b"\0" * 9)) + chunk(b"IEND", b"")
        with self.assertRaises(share.ShareError) as caught:
            share.decode_png(out)
        self.assertIn("16-bit", str(caught.exception))

    def test_an_interlaced_png_is_refused(self):
        out = b"\x89PNG\r\n\x1a\n"
        out += chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 1))
        out += chunk(b"IDAT", zlib.compress(b"\0" * 13)) + chunk(b"IEND", b"")
        with self.assertRaises(share.ShareError) as caught:
            share.decode_png(out)
        self.assertIn("interlaced", str(caught.exception))

    def test_something_that_is_not_a_png_is_refused(self):
        with self.assertRaises(share.ShareError) as caught:
            share.decode_png(b"GIF89a and then some")
        self.assertIn("not a PNG", str(caught.exception))


class Palette(unittest.TestCase):
    def test_three_colours_give_three_colours(self):
        pixels = bytes([10, 20, 30, 200, 100, 50, 0, 0, 0] * 100)
        palette = share.median_cut(share.sample(pixels, 10, 30), 256)
        self.assertEqual(len(palette), 3)
        for want in ((10, 20, 30), (200, 100, 50), (0, 0, 0)):
            self.assertIn(want, palette)

    def test_the_palette_never_exceeds_what_a_gif_colour_table_holds(self):
        palette = share.median_cut(share.sample(ramp(200, 200), 200, 200), 256)
        self.assertLessEqual(len(palette), 256)

    def test_every_pixel_gets_an_index_the_table_has(self):
        # The failure mode is a palette smaller than the indices pointing into
        # it, which decodes to whatever colour happens to be next in the table.
        palette = share.median_cut(share.sample(ramp(64, 64), 64, 64), 16)
        cube = share.build_cube(palette)
        indices = share.quantise(64, 64, ramp(64, 64), cube, palette)
        self.assertEqual(len(indices), 64 * 64)
        self.assertLess(max(indices), len(palette))

    def test_the_cube_always_points_inside_the_palette(self):
        palette = share.median_cut(share.sample(ramp(40, 40), 40, 40), 5)
        cube = share.build_cube(palette)
        self.assertLess(max(cube), len(palette))
        self.assertEqual(len(cube), share.CUBE_SIZE)


class Gif(unittest.TestCase):
    def test_the_frames_decode_back_to_what_was_quantised(self):
        data, palette, frames = encode(32, 24, 3)
        _size, table, decoded, _loops, _delay = gif_frames(data)
        self.assertEqual(len(decoded), 3)
        for (fw, fh, _mcs, pixels), (w, h, indices) in zip(decoded, frames):
            # What a reader gets is the indices, and they have to be the ones
            # that were encoded — a stream that decodes to the right *length* of
            # the wrong numbers is the failure this test exists for.
            self.assertEqual((fw, fh), (w, h))
            self.assertEqual(pixels, bytes(indices))
        # And the table the file carries is the palette it was given, so those
        # indices mean what this test thinks they mean.
        self.assertEqual(len(table), 256)
        self.assertEqual(tuple(table[:len(palette)]), tuple(palette))

    def test_it_loops_forever_at_the_documented_delay(self):
        data, _, _ = encode(16, 16, 2)
        _, _, frames, loops, delay = gif_frames(data)
        self.assertEqual(loops, 0, "a loop count of zero is what loops forever")
        self.assertEqual(delay, share.FRAME_DELAY_CS)
        self.assertEqual(len(frames), 2)

    def test_the_delay_survives_a_value_over_255_centiseconds(self):
        # A GIF delay is in hundredths and is two bytes, and the case that
        # catches the mistake is a value that does not fit in one.
        data, _, _ = encode(8, 8, 1)
        self.assertEqual(gif_frames(data)[4], share.FRAME_DELAY_CS)
        self.assertLess(share.FRAME_DELAY_CS, 256)

    def test_a_frame_big_enough_to_fill_the_code_table_still_decodes(self):
        # Past 4096 codes the encoder has to clear, and a clear in the wrong
        # place desynchronises everything after it. A smooth gradient is the
        # input that fills the table fastest.
        width, height = 240, 180
        data, _, frames = encode(width, height, 1, seed=0)
        self.assertEqual(len(frames[0][2]), width * height)
        _size, _table, decoded, _, _ = gif_frames(data)
        self.assertEqual(len(decoded[0][3]), width * height)

    def test_frames_of_different_sizes_are_refused_rather_than_rescaled(self):
        # Rescaling would mean a resampler. Refusing means the caller sends
        # frames the grab actually produced, which are all one size.
        small = share.quantise(4, 4, ramp(4, 4), share.build_cube([(0, 0, 0), (255, 255, 255)]),
                               [(0, 0, 0), (255, 255, 255)])
        with self.assertRaises(share.ShareError) as caught:
            share.build_gif([(4, 4, small), (8, 8, small)], [(0, 0, 0), (255, 255, 255)], 30)
        self.assertIn("not all the same size", str(caught.exception))


# ---------------------------------------------------------------------------
# The filesystem
# ---------------------------------------------------------------------------


class Home:
    """A home directory for the helper to work in, and a way to run it."""

    def __enter__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = self.tmp.name
        self.saved = os.environ.get("HOME")
        os.environ["HOME"] = self.path
        return self

    def __exit__(self, *exc):
        if self.saved is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = self.saved
        self.tmp.cleanup()

    def run(self, *args):
        return subprocess.run(
            ["/usr/bin/python3", "-I", "-S", str(PLUGIN / "share.py"), *args],
            capture_output=True, text=True,
            env={**os.environ, "HOME": self.path})

    def begin(self, count=1):
        done = self.run("begin", str(count))
        if done.returncode != 0:
            raise AssertionError("share.py begin %d failed: %s" % (count, done.stderr.strip()))
        lines = done.stdout.strip().split("\n")
        if len(lines) != count + 1:
            raise AssertionError("share.py begin %d answered with %d lines" % (count, len(lines)))
        return os.path.basename(lines[0]), lines[1:]

    def share(self):
        return os.path.join(self.path, "Pictures", "akash")

    def plugin_dir(self, mode=0o755):
        """The plugin's own directory, created by the plugin's other code."""
        path = os.path.join(self.path, ".config", "omarchy", "akash")
        os.makedirs(path, exist_ok=True)
        os.chmod(path, mode)
        return path


class ThePluginsOwnDirectory(unittest.TestCase):
    """The one that was a live bug: no share worked on any existing install."""

    def test_a_plugin_directory_that_is_not_private_still_takes_a_share(self):
        # ~/.config/omarchy/akash is created by the rest of the plugin, under
        # the default umask, long before a share happens. Demanding 700 of it
        # refuses every share on every machine that has ever run cams.py — and
        # the only symptom is a toast saying the map was not saved, with the
        # reason on a stream nobody was reading.
        with Home() as home:
            home.plugin_dir(0o755)
            run, frames = home.begin(1)
            Path(frames[0]).write_bytes(png_bytes(4, 4, ramp(4, 4)))
            answer = home.run("finish", run, "image", "akash-radar-20260101-0000")
            self.assertEqual(answer.returncode, 0, answer.stderr)
            self.assertTrue(os.path.isfile(answer.stdout.strip().split("\t")[0]))

    def test_the_share_directory_itself_is_private_not_borrowed(self):
        # The frames are the user's own weather rather than a credential, and
        # the directory that holds them is still 700. Only `share` is claimed.
        with Home() as home:
            home.plugin_dir(0o755)
            home.begin(1)
            created = os.path.join(home.path, ".config", "omarchy", "akash", "share")
            self.assertEqual(os.stat(created).st_mode & 0o777, 0o700)

    def test_the_plugin_directory_is_not_tightened_behind_the_users_back(self):
        # 755 is what the rest of the plugin leaves. A share must not go
        # changing the mode of a directory it merely lives inside.
        with Home() as home:
            plugin = home.plugin_dir(0o755)
            home.begin(1)
            self.assertEqual(os.stat(plugin).st_mode & 0o777, 0o755, plugin)

    def test_a_share_directory_that_is_wide_is_refused_not_repaired(self):
        # Ours, and ours to hold to the rule: a directory that was ever wider
        # may hold entries this plugin did not put there. And the refusal has
        # to name the command that fixes it, because a share that fails for a
        # reason it will not say is the bug that started all of this.
        with Home() as home:
            home.plugin_dir(0o755)
            wide = os.path.join(home.path, ".config", "omarchy", "akash", "share")
            os.makedirs(wide, exist_ok=True)
            os.chmod(wide, 0o755)
            answer = home.run("begin", "1")
            self.assertNotEqual(answer.returncode, 0)
            self.assertIn("700", answer.stderr)
            self.assertIn("chmod 700", answer.stderr)
            self.assertNotIn("Traceback", answer.stderr)


class Refusals(unittest.TestCase):
    def test_a_symlink_at_the_destination_is_replaced_not_written_through(self):
        # The manual's own test, verbatim in spirit: a symlink planted on the
        # name the helper is about to publish to must cost the symlink.
        with Home() as home:
            _run, frames = home.begin()
            png_bytes(4, 4, ramp(4, 4))
            Path(frames[0]).write_bytes(png_bytes(4, 4, ramp(4, 4)))

            os.makedirs(home.share(), exist_ok=True)
            os.chmod(home.share(), 0o700)
            victim = os.path.join(home.path, "victim")
            Path(victim).write_text("must survive")
            target = os.path.join(home.share(), "akash-radar-20260101-0000.png")
            os.symlink(victim, target)

            answer = home.run("finish", _run, "image", "akash-radar-20260101-0000")
            self.assertEqual(answer.returncode, 0, answer.stderr)
            self.assertEqual(Path(victim).read_text(), "must survive")
            # The name is still the planter's symlink and still points at the
            # victim: the helper neither wrote through it nor replaced it, and
            # published the share under a name of its own instead.
            self.assertTrue(os.path.islink(target))
            self.assertEqual(os.readlink(target), victim)
            self.assertTrue(os.path.isfile(answer.stdout.strip().split("\t")[0]))

    def test_the_published_file_is_private(self):
        with Home() as home:
            run, frames = home.begin()
            Path(frames[0]).write_bytes(png_bytes(4, 4, ramp(4, 4)))
            answer = home.run("finish", run, "image", "akash-radar-20260101-0000")
            path = answer.stdout.strip().split("\t")[0]
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

    def test_a_fifo_planted_as_a_frame_does_not_hang_the_shell(self):
        # O_NONBLOCK is what makes this a refusal rather than a hang, and a hang
        # inside the one process that owns the bar and every panel is the worst
        # failure this file could have.
        with Home() as home:
            run, frames = home.begin()
            os.mkfifo(frames[0])
            answer = home.run("finish", run, "image", "akash-radar-20260101-0000")
            self.assertNotEqual(answer.returncode, 0)
            self.assertNotIn("Traceback", answer.stderr)
            self.assertIn("refusing", answer.stderr)

    def test_a_frame_that_is_a_symlink_is_refused(self):
        with Home() as home:
            run, frames = home.begin()
            victim = os.path.join(home.path, "victim")
            Path(victim).write_text("must survive")
            os.symlink(victim, frames[0])
            answer = home.run("finish", run, "image", "akash-radar-20260101-0000")
            self.assertNotEqual(answer.returncode, 0)
            self.assertNotIn("Traceback", answer.stderr)
            self.assertEqual(Path(victim).read_text(), "must survive")

    def test_an_oversized_frame_is_refused_rather_than_truncated(self):
        with Home() as home:
            run, frames = home.begin()
            Path(frames[0]).write_bytes(b"\x89PNG\r\n\x1a\n"
                                        + b"\0" * (share.MAX_FRAME_BYTES + 1))
            answer = home.run("finish", run, "image", "akash-radar-20260101-0000")
            self.assertNotEqual(answer.returncode, 0)
            self.assertIn("ceiling", answer.stderr)

    def test_a_run_directory_name_cannot_walk_out_of_the_state_directory(self):
        with Home() as home:
            for name in ("..", ".", "../../etc", "/etc", "a/b", ".run-x/../.."):
                with self.subTest(run=name):
                    done = home.run("finish", name, "image", "akash-radar-20260101-0000")
                    self.assertNotEqual(done.returncode, 0)
                    self.assertNotIn("Traceback", done.stderr)
                    self.assertIn("refusing", done.stderr)

    def test_a_file_stem_cannot_carry_a_separator_or_lead_with_a_dash(self):
        with Home() as home:
            for stem in ("../evil", "a/b", "-dash", "UPPER", "", "a b", "x" * 70):
                with self.subTest(stem=stem):
                    run, frames = home.begin()
                    Path(frames[0]).write_bytes(png_bytes(4, 4, ramp(4, 4)))
                    answer = home.run("finish", run, "image", stem)
                    self.assertNotEqual(answer.returncode, 0, answer.stdout)
                    self.assertNotIn("Traceback", answer.stderr)

    def test_a_state_directory_that_is_a_symlink_is_refused_not_followed(self):
        with Home() as home:
            parent = os.path.join(home.path, ".config", "omarchy")
            os.makedirs(parent)
            elsewhere = os.path.join(home.path, "elsewhere")
            os.makedirs(elsewhere)
            os.symlink(elsewhere, os.path.join(parent, "akash"))
            answer = home.run("begin", "1")
            self.assertNotEqual(answer.returncode, 0, answer.stdout)
            self.assertIn("refusing", answer.stderr)
            self.assertNotIn("Traceback", answer.stderr)
            self.assertEqual(os.listdir(elsewhere), [])

    def test_nothing_ever_answers_with_a_traceback(self):
        # Every refusal is a sentence. A traceback is a stack of this file's
        # internals, and the panel has nowhere to put one.
        with Home() as home:
            cases = [
                ("begin", "abc"), ("begin", ""), ("begin", "1.5"), ("begin", "0x8"),
                ("begin", "17"), ("begin", "0"),
                ("finish", "x", "image", "ok"), ("finish", ".run-1", "bogus", "ok"),
                ("finish", ".run-1", "image", "OK"),
                ("abort", ".."), ("abort", ""), ("nope",), (), ("finish",),
                ("finish", "a", "b", "c", "d", "e"),
            ]
            for case in cases:
                with self.subTest(case=case):
                    answer = home.run(*case)
                    self.assertNotEqual(answer.returncode, 0)
                    self.assertNotIn("Traceback", answer.stderr)
                    self.assertTrue(answer.stderr.strip(), "a refusal with no sentence")


class Cleanliness(unittest.TestCase):
    def test_a_finished_share_leaves_no_run_directory(self):
        # A state directory that grows by a few megabytes per export and is
        # pruned by nothing is a slow disk-full, and the case that matters is
        # the failed one, where nothing else would ever come back for it.
        with Home() as home:
            for mode, count in (("image", 1), ("gif", 2)):
                run, frames = home.begin(count)
                for index in range(count):
                    Path(frames[index]).write_bytes(png_bytes(8, 8, ramp(8, 8, index)))
                answer = home.run("finish", run, mode, "akash-radar-20260101-0000")
                self.assertEqual(answer.returncode, 0, answer.stderr)
                share_dir = os.path.join(home.path, ".config", "omarchy", "akash", "share")
                self.assertEqual([e for e in os.listdir(share_dir) if e.startswith(".run-")], [])

    def test_a_failed_share_leaves_no_run_directory_either(self):
        with Home() as home:
            run, frames = home.begin(2)
            # A frame that is not a PNG fails the encode, which is the case
            # where nothing would otherwise ever come back for the directory.
            Path(frames[0]).write_bytes(b"\x89PNG\r\n\x1a\x0b" + b"\0" * 32)
            Path(frames[1]).write_bytes(png_bytes(8, 8, ramp(8, 8, 1)))
            answer = home.run("finish", run, "gif", "akash-radar-20260101-0000")
            self.assertNotEqual(answer.returncode, 0, answer.stdout)
            share_dir = os.path.join(home.path, ".config", "omarchy", "akash", "share")
            self.assertEqual([e for e in os.listdir(share_dir) if e.startswith(".run-")], [])

    def test_abort_is_idempotent(self):
        # Component.onDestruction and a cancel can both arrive for the same
        # share, and the second one must not be an error the user sees.
        with Home() as home:
            run, _ = home.begin(3)
            self.assertEqual(home.run("abort", run).returncode, 0)
            self.assertEqual(home.run("abort", run).returncode, 0)

    def test_a_name_already_taken_gets_a_counter_rather_than_an_overwrite(self):
        with Home() as home:
            run, frames = home.begin()
            Path(frames[0]).write_bytes(png_bytes(4, 4, ramp(4, 4)))
            one = home.run("finish", run, "image", "akash-radar-20260101-0000").stdout.split("\t")[0]

            run, frames = home.begin()
            Path(frames[0]).write_bytes(png_bytes(4, 4, ramp(4, 4, 1)))
            two = home.run("finish", run, "image", "akash-radar-20260101-0000").stdout.split("\t")[0]

            self.assertNotEqual(one, two)
            self.assertTrue(two.endswith("-2.png"), two)
            # And the first share is still there, not replaced by the second.
            self.assertTrue(os.path.exists(one))


class Answer(unittest.TestCase):
    def test_the_answer_is_a_path_and_a_count(self):
        with Home() as home:
            run, frames = home.begin()
            Path(frames[0]).write_bytes(png_bytes(4, 4, ramp(4, 4)))
            answer = home.run("finish", run, "image", "akash-radar-20260101-0000").stdout
            self.assertEqual(len(answer.strip().split("\n")), 1)
            path, count = answer.strip().split("\t")
            self.assertTrue(path.startswith(home.path + "/Pictures/akash/"))
            self.assertEqual(int(count), os.stat(path).st_size)

    def test_stdout_stays_under_its_ceiling(self):
        # The panel collects this into the shell process, so the helper holds
        # itself to the bound the panel then checks a second time.
        with Home() as home:
            run, frames = home.begin(16)
            self.assertLessEqual(len(home.run("begin", "16").stdout), share.MAX_STDOUT_BYTES)
            self.assertEqual(len(frames), 16)


if __name__ == "__main__":
    unittest.main(verbosity=2)
