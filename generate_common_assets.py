"""
Script to generate default NPR common textures for ZZZ Shader:
- toon_ramp.vtf: default ZZZ slot ramp (see tools/zzz_ramp_from_json.py)
- neutral_*.vtf / black.vtf: fallbacks for missing texture slots
- rim_curve.vtf: Crisp anime silhouette rim curve
- metal_matcap.vtf: Stylized anime silver/steel metallic sphere map
- metal_matcap_gold.vtf: Stylized anime gold metallic sphere map
- metal_matcap_chrome.vtf: Half-Life style high-contrast chrome sphere map
"""
import struct, math, os

def save_vtf_bgra(filepath, width, height, rgba_data, clamp=True):
    # Flags: NOMIP (0x0100) | NOLOD (0x0200)
    flags = 0x00000300
    if clamp:
        flags |= 0x0000000C # CLAMP_S | CLAMP_T

    # Native BGRA8888 (D3DFMT_A8R8G8B8)
    bgra = bytearray(width * height * 4)
    for i in range(width * height):
        r = rgba_data[i*4 + 0]
        g = rgba_data[i*4 + 1]
        b = rgba_data[i*4 + 2]
        a = rgba_data[i*4 + 3]
        bgra[i*4 + 0] = b
        bgra[i*4 + 1] = g
        bgra[i*4 + 2] = r
        bgra[i*4 + 3] = a

    header = bytearray(80)
    struct.pack_into('<4sIIIHHIHH4xfff4xfiBiBBH', header, 0,
        b'VTF\0',
        7, 2,       # version 7.2
        80,         # header size
        width, height,
        flags,
        1,          # num frames
        0,          # start frame
        1.0, 1.0, 1.0, # reflectivity
        1.0,        # bump scale
        12,         # BGRA8888
        1,          # num mip levels = 1
        -1,         # low res image format = None
        0, 0,       # low res width/height
        1           # depth
    )
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    with open(filepath, 'wb') as f:
        f.write(header)
        f.write(bgra)
    print(f"Generated: {filepath} ({width}x{height})")


# 1. TOON RAMP (256x8) - default ZZZ slot colours, same layout as tools/zzz_ramp_from_json.py:
# rows 0-4 = material slots (picked by LightMap.R), row 5 = specular colour, row 6 = outline colour.
# For a real character, bake its own ramp from the game material JSON with that tool.
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
from zzz_ramp_from_json import build as build_ramp, write_vtf as write_ramp_vtf
default_ramp_rows = build_ramp({"m_Shader": {"Name": "default"},
                                "m_SavedProperties": {"m_Colors": {}, "m_Floats": {}}})


# 2. RIM CURVE (256x16)
# Black across center, sharp rise only at extreme silhouette edge (> 0.82)
rim = bytearray(256 * 16 * 4)
for y in range(16):
    for x in range(256):
        t = x / 255.0
        if t < 0.80:
            val = 0
        else:
            # Exponential rise to peak white
            norm = (t - 0.80) / 0.20
            val = int(255 * (norm ** 2.5))
        idx = (y * 256 + x) * 4
        rim[idx:idx+4] = bytes([val, val, val, 255])


# 3. STYLIZED ANIME STEEL MATCAP (256x256)
matcap_steel = bytearray(256 * 256 * 4)
for y in range(256):
    ny = (y / 255.0) * 2.0 - 1.0 # -1 to 1
    for x in range(256):
        nx = (x / 255.0) * 2.0 - 1.0 # -1 to 1
        dist_sqr = nx*nx + ny*ny
        if dist_sqr > 1.0:
            r, g, b, a = 0, 0, 0, 0
        else:
            nz = math.sqrt(1.0 - dist_sqr)
            # Diffuse ambient sphere lighting from top-left
            diff = max(0.0, nx * -0.4 + ny * -0.5 + nz * 0.7)
            # Specular highlight dot
            spec = max(0.0, nx * -0.45 + ny * -0.55 + nz * 0.7) ** 16.0
            
            base_r = 160 + int(70 * diff) + int(255 * spec)
            base_g = 170 + int(70 * diff) + int(255 * spec)
            base_b = 190 + int(60 * diff) + int(255 * spec)
            r = min(255, base_r)
            g = min(255, base_g)
            b = min(255, base_b)
            a = 255
        idx = (y * 256 + x) * 4
        matcap_steel[idx:idx+4] = bytes([r, g, b, a])


# 4. STYLIZED ANIME GOLD MATCAP (256x256)
matcap_gold = bytearray(256 * 256 * 4)
for y in range(256):
    ny = (y / 255.0) * 2.0 - 1.0
    for x in range(256):
        nx = (x / 255.0) * 2.0 - 1.0
        dist_sqr = nx*nx + ny*ny
        if dist_sqr > 1.0:
            r, g, b, a = 0, 0, 0, 0
        else:
            nz = math.sqrt(1.0 - dist_sqr)
            diff = max(0.0, nx * -0.4 + ny * -0.5 + nz * 0.7)
            spec = max(0.0, nx * -0.45 + ny * -0.55 + nz * 0.7) ** 18.0
            
            # Rich golden amber tones
            base_r = 210 + int(45 * diff) + int(255 * spec)
            base_g = 165 + int(50 * diff) + int(255 * spec)
            base_b = 60 + int(40 * diff) + int(200 * spec)
            r = min(255, base_r)
            g = min(255, base_g)
            b = min(255, base_b)
            a = 255
        idx = (y * 256 + x) * 4
        matcap_gold[idx:idx+4] = bytes([r, g, b, a])


# 5. HALF-LIFE CLASSIC CHROME SPHERE MAP (256x256)
# Recreates GoldSrc/Source chrome: dark horizon, sky gradient, bright specular band
matcap_chrome = bytearray(256 * 256 * 4)
for y in range(256):
    ny = (y / 255.0) * 2.0 - 1.0
    for x in range(256):
        nx = (x / 255.0) * 2.0 - 1.0
        dist_sqr = nx*nx + ny*ny
        if dist_sqr > 1.0:
            r, g, b, a = 0, 0, 0, 0
        else:
            nz = math.sqrt(1.0 - dist_sqr)
            # Classic HL chrome horizon banding
            elevation = ny # -1 (top) to 1 (bottom)
            
            # Sharp horizon reflection cut around center
            if elevation < -0.1:
                # Sky reflection (gradient blue-gray to bright horizon)
                t = (-elevation - 0.1) / 0.9
                lum = 120 + int(120 * (1.0 - t))
                # Add primary light reflection
                spec = max(0.0, nx * -0.4 + ny * -0.6 + nz * 0.7) ** 12.0
                lum += int(255 * spec)
            elif elevation < 0.1:
                # Dark ground horizon line
                lum = 40 + int(30 * abs(elevation) / 0.1)
            else:
                # Ground reflection (warm copper-brown bounce)
                t = (elevation - 0.1) / 0.9
                lum = 70 + int(100 * math.sin(t * 3.14159))
            
            lum = min(255, max(0, lum))
            r, g, b = lum, lum, int(lum * 1.05) if lum < 240 else 255
            a = 255
        idx = (y * 256 + x) * 4
        matcap_chrome[idx:idx+4] = bytes([min(255, r), min(255, g), min(255, b), a])


def solid(r, g, b, a, size=4):
    return bytearray(bytes([r, g, b, a]) * (size * size))


# Neutral fallbacks used by the Lua proxy when a slot is missing
neutral_normal      = solid(128, 128, 255, 255)  # flat normal, B = 1 (no occlusion)
neutral_lightmap    = solid(0, 0, 128, 255)      # ramp row 0, not metallic, mid gloss
neutral_materialmap = solid(255, 0, 0, 255)      # opaque, no spec tint, no specular
black               = solid(0, 0, 0, 0)          # no emission

out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "addon", "materials", "models", "zzz", "common")
write_ramp_vtf(default_ramp_rows, os.path.join(out_dir, "toon_ramp.vtf"))
save_vtf_bgra(os.path.join(out_dir, "rim_curve.vtf"), 256, 16, rim)
save_vtf_bgra(os.path.join(out_dir, "metal_matcap.vtf"), 256, 256, matcap_steel)
save_vtf_bgra(os.path.join(out_dir, "metal_matcap_gold.vtf"), 256, 256, matcap_gold)
save_vtf_bgra(os.path.join(out_dir, "metal_matcap_chrome.vtf"), 256, 256, matcap_chrome)
save_vtf_bgra(os.path.join(out_dir, "neutral_normal.vtf"), 4, 4, neutral_normal, clamp=False)
save_vtf_bgra(os.path.join(out_dir, "neutral_lightmap.vtf"), 4, 4, neutral_lightmap, clamp=False)
save_vtf_bgra(os.path.join(out_dir, "neutral_materialmap.vtf"), 4, 4, neutral_materialmap, clamp=False)
save_vtf_bgra(os.path.join(out_dir, "black.vtf"), 4, 4, black, clamp=False)

print("Common NPR textures generated. Run install_to_gmod.bat to deploy.")
