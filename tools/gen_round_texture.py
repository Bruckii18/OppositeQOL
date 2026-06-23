#!/usr/bin/env python3
"""Generate OppositeQOL's rounded-corner UI textures.

These are self-authored assets (no third-party art) used by UI.ApplyRoundedBackdrop
as 9-slice textures (Texture:SetTextureSliceMargins). Two 128x128, 32-bit, white-
on-transparent textures are produced, tinted at runtime via SetVertexColor:

  Opposite_RoundFill_128.tga   filled rounded rectangle (card / panel background)
  Opposite_RoundEdge_128.tga   rounded-rectangle outline (hairline border)

TGA format matches the bundled logo exactly: 18-byte header, image type 2
(uncompressed true-colour), 32 bpp, descriptor 0x28 (top-left origin, 8 alpha
bits), straight (non-premultiplied) BGRA. Dimensions are power-of-two.

Run from the project root:  python3 tools/gen_round_texture.py
PNG previews (on a dark background) are written to /tmp for visual checking.
"""

import math
import os
import struct
import zlib

SIZE = 128          # power-of-two
RADIUS = 24.0       # corner radius in native pixels
STROKE = 3.0        # outline thickness in native pixels
MEDIA = os.path.join(os.path.dirname(__file__), "..", "Media")


def _rr_sdf(px, py, half, radius):
    """Signed distance to a rounded rectangle centred in the texture.
    half = (hx, hy) box half-size; radius = corner radius. Negative inside."""
    qx = abs(px - SIZE / 2) - half[0] + radius
    qy = abs(py - SIZE / 2) - half[1] + radius
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    return outside + inside - radius


def _cov(sdf):
    """1px anti-aliased coverage from a signed distance (1 inside, 0 outside)."""
    return max(0.0, min(1.0, 0.5 - sdf))


def fill_alpha(px, py):
    return _cov(_rr_sdf(px, py, (SIZE / 2, SIZE / 2), RADIUS))


def edge_alpha(px, py):
    outer = _cov(_rr_sdf(px, py, (SIZE / 2, SIZE / 2), RADIUS))
    inner = _cov(_rr_sdf(px, py, (SIZE / 2 - STROKE, SIZE / 2 - STROKE), max(RADIUS - STROKE, 0.0)))
    return max(0.0, min(1.0, outer - inner))


def write_tga(path, alpha_fn):
    """Write a 32-bit BGRA TGA (white RGB, per-pixel alpha), logo-matching format."""
    header = struct.pack(
        "<BBBHHBHHHHBB",
        0,      # id length
        0,      # colour map type
        2,      # image type: uncompressed true-colour
        0, 0, 0,  # colour map spec (origin, length, depth)
        0,      # x-origin
        0,      # y-origin
        SIZE,   # width
        SIZE,   # height
        32,     # bpp
        0x28,   # descriptor: top-left origin, 8 alpha bits
    )
    out = bytearray(header)
    for y in range(SIZE):            # top-left origin: rows top -> bottom
        for x in range(SIZE):
            a = int(round(alpha_fn(x + 0.5, y + 0.5) * 255))
            out += bytes((255, 255, 255, a))  # B, G, R, A (white, tint at runtime)
    with open(path, "wb") as f:
        f.write(out)
    return len(out)


def write_png_preview(path, alpha_fn, tint):
    """Composite the white shape (tinted) over a dark bg into an 8-bit RGB PNG."""
    bg = (0x0d, 0x0d, 0x0f)
    raw = bytearray()
    for y in range(SIZE):
        raw.append(0)  # filter type 0 for this scanline
        for x in range(SIZE):
            a = alpha_fn(x + 0.5, y + 0.5)
            for c in range(3):
                raw.append(int(round(tint[c] * a + bg[c] * (1 - a))))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)  # 8-bit, colour type 2 (RGB)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def main():
    os.makedirs(MEDIA, exist_ok=True)
    n1 = write_tga(os.path.join(MEDIA, "Opposite_RoundFill_128.tga"), fill_alpha)
    n2 = write_tga(os.path.join(MEDIA, "Opposite_RoundEdge_128.tga"), edge_alpha)
    write_png_preview("/tmp/round_fill_preview.png", fill_alpha, (0x2f, 0xe3, 0xc4))
    write_png_preview("/tmp/round_edge_preview.png", edge_alpha, (0x2f, 0xe3, 0xc4))
    expect = 18 + SIZE * SIZE * 4
    print("Opposite_RoundFill_128.tga  %d bytes (expect %d) %s" % (n1, expect, "OK" if n1 == expect else "BAD"))
    print("Opposite_RoundEdge_128.tga  %d bytes (expect %d) %s" % (n2, expect, "OK" if n2 == expect else "BAD"))
    print("previews: /tmp/round_fill_preview.png  /tmp/round_edge_preview.png")


if __name__ == "__main__":
    main()
