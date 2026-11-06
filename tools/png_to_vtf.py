"""
Convert a PNG/TGA/DDS (anything Pillow can open) into an uncompressed BGRA8888 VTF with mipmaps.

Usage:
    python tools/png_to_vtf.py <input image> <output.vtf> [--clamp] [--nomip]

Typical use, the ZZZ face shadow map:
    python tools/png_to_vtf.py Female_Face_Lightmap.png .../materials/<model>/face_lightmap.vtf --clamp

Data maps (face shadow map, _M, _A, _N) are stored as-is; the VMT reads them with $linearread_textureN 1.
"""
import argparse
import os
import struct

from PIL import Image

FLAG_CLAMPS = 0x0004
FLAG_CLAMPT = 0x0008
FLAG_NOMIP = 0x0100
FLAG_NOLOD = 0x0200
FMT_BGRA8888 = 12


def to_bgra(img):
    r, g, b, a = img.split()
    return Image.merge("RGBA", (b, g, r, a)).tobytes()


def write_vtf(src, dst, clamp=False, mips=True, quiet=False):
    """src: an image path, or a PIL image (used by the other tools)."""
    img = src.convert("RGBA") if isinstance(src, Image.Image) else Image.open(src).convert("RGBA")
    if isinstance(src, Image.Image):
        src = "image"
    w, h = img.size
    if w & (w - 1) or h & (h - 1):
        raise SystemExit(f"{src}: size {w}x{h} is not a power of two")

    levels = [img]
    if mips:
        while levels[-1].size != (1, 1):
            lw, lh = levels[-1].size
            levels.append(levels[-1].resize((max(1, lw // 2), max(1, lh // 2)), Image.LANCZOS))

    flags = FLAG_NOLOD | (0 if mips else FLAG_NOMIP) | ((FLAG_CLAMPS | FLAG_CLAMPT) if clamp else 0)
    header = bytearray(80)
    struct.pack_into('<4sIIIHHIHH4xfff4xfiBiBBH', header, 0,
                     b'VTF\0', 7, 2, 80, w, h, flags,
                     1, 0,               # frames, first frame
                     1.0, 1.0, 1.0,      # reflectivity
                     1.0,                # bump scale
                     FMT_BGRA8888, len(levels),
                     -1, 0, 0,           # no low-res image
                     1)                  # depth

    os.makedirs(os.path.dirname(os.path.abspath(dst)), exist_ok=True)
    with open(dst, "wb") as f:
        f.write(header)
        for level in reversed(levels):    # VTF stores the smallest mip first
            f.write(to_bgra(level))
    if not quiet:
        print(f"{src} -> {dst} ({w}x{h}, {len(levels)} mip levels)")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--clamp", action="store_true", help="clamp UVs instead of wrapping")
    ap.add_argument("--nomip", action="store_true", help="no mipmaps")
    args = ap.parse_args()
    write_vtf(args.input, args.output, clamp=args.clamp, mips=not args.nomip)
