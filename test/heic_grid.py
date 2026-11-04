#!/usr/bin/env python3
"""Writes a HEIC laid out the way iPhone cameras save photos: a grid of HEVC
tiles cropped to the picture size, rotated with `irot` and tagged Display P3.
Each tile is encoded with a full FFmpeg (libx265) and copied out of its MP4.

Usage: heic_grid.py <full ffmpeg> <out.heic>
       heic_grid.py --check <decoded 400x500 RGBA>

The 500x400 picture (stored landscape, shown portrait after a quarter turn
anticlockwise) has four solid quadrants split at 256: red top left, green top
right, blue bottom left, white bottom right. 2x2 tiles of 256 cover 512x512,
so the grid is cropped on the right and bottom like a 4032x3024 photo.
"""

import struct
import subprocess
import sys
import tempfile
from pathlib import Path

TILE, COLUMNS, ROWS = 256, 2, 2
WIDTH, HEIGHT = 500, 400
COLOURS = [["red", "lime"], ["blue", "white"]]


def box(kind, payload):
    return struct.pack(">I4s", 8 + len(payload), kind) + payload


def full_box(kind, version, flags, payload):
    return box(kind, struct.pack(">I", (version << 24) | flags) + payload)


def children(data, start, end):
    """(kind, payload start, payload end) for each box in data[start:end]."""
    while start + 8 <= end:
        size, kind = struct.unpack(">I4s", data[start : start + 8])
        yield kind, start + 8, start + size
        start += size


def find(data, path, start=0, end=None):
    end = len(data) if end is None else end
    kind, *rest = path
    # Container payload offsets: stsd is a full box with an entry count, and
    # a visual sample entry has 78 bytes of fields before its child boxes.
    skip = {b"stsd": 8, b"hvc1": 78}
    for found, payload, finish in children(data, start, end):
        if found == kind:
            payload += skip.get(kind, 0)
            return (payload, finish) if not rest else find(data, rest, payload, finish)
    raise SystemExit(f"heic_grid.py: no {kind!r} box in the tile MP4")


def tile(ffmpeg, work, row, column):
    """One encoded tile: its hvcC configuration and its sample (length-prefixed NAL units)."""
    path = work / f"tile-{row}-{column}.mp4"
    colour = COLOURS[row][column]
    subprocess.run(
        [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
         "-f", "lavfi", "-i", f"color=c={colour}:size={TILE}x{TILE}", "-frames:v", "1",
         "-vf", "format=yuv420p", "-c:v", "libx265", "-x265-params", "log-level=error",
         "-color_primaries", "smpte432", "-color_trc", "iec61966-2-1", "-colorspace", "bt709",
         "-tag:v", "hvc1", str(path)],
        check=True,
    )
    data = path.read_bytes()
    start, end = find(data, [b"moov", b"trak", b"mdia", b"minf", b"stbl", b"stsd", b"hvc1", b"hvcC"])
    hvcc = data[start:end]
    start, end = find(data, [b"mdat"])
    return hvcc, data[start:end]


def main():
    ffmpeg, out = sys.argv[1], Path(sys.argv[2])
    with tempfile.TemporaryDirectory() as work:
        tiles = [tile(ffmpeg, Path(work), row, column) for row in range(ROWS) for column in range(COLUMNS)]

    grid_id, tile_ids = 1, list(range(2, 2 + len(tiles)))
    # ImageGrid: version 0, 16-bit sizes, rows-1, columns-1, output size.
    grid = struct.pack(">BBBBHH", 0, 0, ROWS - 1, COLUMNS - 1, WIDTH, HEIGHT)
    payloads = [grid] + [sample for _, sample in tiles]

    infe = [full_box(b"infe", 2, 0, struct.pack(">HH4s", grid_id, 0, b"grid") + b"\0")]
    # Tiles are hidden: only the grid is a picture.
    infe += [full_box(b"infe", 2, 1, struct.pack(">HH4s", i, 0, b"hvc1") + b"\0") for i in tile_ids]
    properties = [box(b"hvcC", hvcc) for hvcc, _ in tiles] + [
        full_box(b"ispe", 0, 0, struct.pack(">II", TILE, TILE)),
        full_box(b"ispe", 0, 0, struct.pack(">II", WIDTH, HEIGHT)),
        # nclx: Display P3 primaries, sRGB transfer, BT.709 matrix, limited range.
        box(b"colr", b"nclx" + struct.pack(">HHHB", 12, 13, 1, 0)),
        box(b"irot", bytes([1])),  # a quarter turn anticlockwise
    ]
    tile_ispe, grid_ispe, colr, irot = (len(tiles) + n for n in range(1, 5))
    associations = [(grid_id, [grid_ispe, colr, 0x80 | irot])]
    associations += [(i, [0x80 | (n + 1), tile_ispe]) for n, i in enumerate(tile_ids)]
    ipma = struct.pack(">I", len(associations)) + b"".join(
        struct.pack(">HB", item, len(indices)) + bytes(indices) for item, indices in associations
    )

    def meta(offsets):
        iloc = struct.pack(">BBH", 0x44, 0x00, len(payloads)) + b"".join(
            struct.pack(">HHHII", item, 0, 1, offset, len(payload))
            for item, offset, payload in zip([grid_id] + tile_ids, offsets, payloads)
        )
        return full_box(b"meta", 0, 0, b"".join([
            full_box(b"hdlr", 0, 0, struct.pack(">I4s12x", 0, b"pict") + b"\0"),
            full_box(b"pitm", 0, 0, struct.pack(">H", grid_id)),
            full_box(b"iloc", 0, 0, iloc),
            full_box(b"iinf", 0, 0, struct.pack(">H", len(infe)) + b"".join(infe)),
            full_box(b"iref", 0, 0, box(b"dimg", struct.pack(">HH", grid_id, len(tile_ids))
                                        + b"".join(struct.pack(">H", i) for i in tile_ids))),
            box(b"iprp", box(b"ipco", b"".join(properties)) + full_box(b"ipma", 0, 0, ipma)),
        ]))

    ftyp = box(b"ftyp", b"heic" + struct.pack(">I", 0) + b"mif1heic")
    # The offsets only change the iloc values, not the meta box size.
    head = len(ftyp) + len(meta([0] * len(payloads))) + 8
    offsets, position = [], head
    for payload in payloads:
        offsets.append(position)
        position += len(payload)
    out.write_bytes(ftyp + meta(offsets) + box(b"mdat", b"".join(payloads)))


def check(path):
    """Asserts a decoded RGBA frame is the picture upright at 400x500."""
    pixels = Path(path).read_bytes()
    assert len(pixels) == HEIGHT * WIDTH * 4, len(pixels)
    expected = {(50, 50): "010", (350, 50): "111", (50, 450): "100", (350, 450): "001"}
    for (x, y), channels in expected.items():
        at = (y * HEIGHT + x) * 4
        pixel = tuple(pixels[at : at + 3])
        assert all((value > 150) == (high == "1") for value, high in zip(pixel, channels)), (x, y, pixel)


if __name__ == "__main__":
    check(sys.argv[2]) if sys.argv[1] == "--check" else main()
