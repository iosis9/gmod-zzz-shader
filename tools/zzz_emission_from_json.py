"""
Bake a ZZZ emission texture ($texture7, "_E") from the game's material JSON and textures.

ZZZ has no emission texture. A material glows when its JSON has _Emission 1; each material slot
(picked by LightMap.R, same as the ramps) has its own HDR _EmissionColorN, and the MaterialMap (_A)
blue channel marks which pixels glow. The glow is coloured by the diffuse:
    glow = diffuse x slot emission colour x MaterialMap.B      (only when _Emission is 1)
Unused slots default to white (1,1,1) in materials with emission off, so the _Emission flag is what
decides, not the colours.

This writes that as an _E texture for zzz_body_ps30:
    RGB = diffuse x (slot colour / brightest slot colour)   (sRGB)
    A   = MaterialMap.B (near-white values only) inside slots whose emission colour isn't black, else 0
and prints the emissionscale (the brightest slot colour) to put in the material's ZZZ proxy block.

Usage:
    python tools/zzz_emission_from_json.py "Harumasa - Default.zip" weapon_e.vtf \\
        --member MAT_Harumasa_Weapon_UI.json --textures Harumasa_Weapon

--textures is the texture name prefix: <prefix>_D.png, <prefix>_M.png and <prefix>_A.png are read
from the zip (or the folder given as input). Nothing is written if the material doesn't glow.
"""
import argparse
import io
import os
import sys
import zipfile

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from png_to_vtf import write_vtf                      # noqa: E402
from zzz_ramp_from_json import load_material, SLOTS   # noqa: E402


def load_texture(source, name):
    if zipfile.is_zipfile(source):
        z = zipfile.ZipFile(source)
        match = [n for n in z.namelist() if n.lower().endswith("/" + name.lower()) or n.lower() == name.lower()]
        if not match:
            raise SystemExit(f"{name} not found in {source}")
        return Image.open(io.BytesIO(z.read(match[0])))
    return Image.open(os.path.join(source, name))


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def slot_emission_colors(mat):
    props = mat["m_SavedProperties"]
    if float(props["m_Floats"].get("_Emission", 0)) < 0.5:
        return None
    colors = []
    for s in range(SLOTS):
        c = props["m_Colors"].get("_EmissionColor" if s == 0 else f"_EmissionColor{s + 1}")
        colors.append((c["r"], c["g"], c["b"]) if c else (0.0, 0.0, 0.0))
    return colors


# Optional: skip maps where fewer than this % of pixels glow. Off by default: a single small light
# is tiny (Harumasa's Body 1 has one indicator light, 0.01% of its texture).
MIN_COVERAGE = 0.0


def build(source, mat, prefix):
    colors = slot_emission_colors(mat)
    if colors is None:
        return None, "emission is off in the JSON (_Emission 0)"
    brightest = max(max(c) for c in colors)
    if brightest <= 0.0:
        return None, "every slot's emission colour is black"

    diffuse = load_texture(source, f"{prefix}_D.png").convert("RGB")
    size = diffuse.size
    lightmap = load_texture(source, f"{prefix}_M.png").convert("RGBA").resize(size, Image.NEAREST)
    matmap = load_texture(source, f"{prefix}_A.png").convert("RGBA").resize(size, Image.BILINEAR)

    d = np.asarray(diffuse, dtype=np.float32) / 255.0
    slot_r = np.asarray(lightmap, dtype=np.float32)[..., 0] / 255.0
    mask = np.asarray(matmap, dtype=np.float32)[..., 2] / 255.0

    # Slot per pixel: LightMap.R in reverse (R 1.0 -> slot 1 ... R 0 -> slot 5), as in the shader
    slot = np.clip(np.floor((1.0 - slot_r) * 4.0 + 0.5), 0, SLOTS - 1).astype(np.int32)
    tint = np.array(colors, dtype=np.float32)[slot] / brightest          # HxWx3, 0..1
    emissive = tint.max(axis=2) > 1e-4
    # Lights are pure white in MaterialMap.B; its mid-grey values are the specular mask and would
    # otherwise glow faintly over whole panels (Harumasa's Weapon 2, slot 5). Keep near-white only.
    alpha = np.where(emissive, np.clip((mask - 0.5) / 0.3, 0.0, 1.0), 0.0)
    if alpha.max() < 1.0 / 255.0:
        return None, "the MaterialMap blue channel is black in every emissive slot"

    coverage = float((alpha > 0.5).mean()) * 100.0
    if coverage < MIN_COVERAGE:
        return None, (f"only {coverage:.3f}% of pixels are marked (below --min-coverage); "
                      f"use --min-coverage 0 to write it anyway")

    rgb = linear_to_srgb(srgb_to_linear(d) * tint)
    out = np.dstack([rgb, alpha])
    img = Image.fromarray((out * 255.0 + 0.5).astype(np.uint8))
    return (img, brightest, colors, coverage), None


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", help="zip from the game export, or a folder with the JSON and PNGs")
    ap.add_argument("output", help="output _E .vtf")
    ap.add_argument("--member", help="material JSON file name inside the zip")
    ap.add_argument("--textures", required=True, help="texture name prefix, e.g. Harumasa_Weapon")
    ap.add_argument("--min-coverage", type=float, default=MIN_COVERAGE,
                    help=f"skip if fewer than this %% of pixels glow (default {MIN_COVERAGE})")
    a = ap.parse_args()
    MIN_COVERAGE = a.min_coverage

    mat = load_material(a.input, a.member)
    result, why = build(a.input, mat, a.textures)
    if result is None:
        print(f"no emission: {why}; nothing written")
        sys.exit(0)
    img, brightest, colors, coverage = result
    write_vtf(img, a.output, mips=False)   # no mipmaps for emission maps
    lit = [f"slot {i + 1} ({', '.join(f'{v:.2f}' for v in c)})" for i, c in enumerate(colors) if max(c) > 0]
    print(f"emissive slots: {'; '.join(lit)}   glowing pixels: {coverage:.2f}%")
    print("VMT:")
    print(f'    $texture7       "<path>/{os.path.splitext(os.path.basename(a.output))[0]}"')
    print(f"    emissionscale   {brightest:.2f}    (proxy block; lower it for a softer glow)")
