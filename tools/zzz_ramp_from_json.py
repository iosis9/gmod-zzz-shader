"""
Build a ZZZ toon ramp VTF from a game material JSON (miHoYo/Character/NapAvatar* shaders).

ZZZ characters don't use a ramp texture (_RampSource 0, _CharacterRampTex empty). Each material has
up to 5 "slots" picked by LightMap.R in reverse (R 1.0, 0.69, 0.5, 0.29, 0 -> slot 1..5),
and every slot defines its own colours:
    _ShallowColorN / _ShallowFadeColorN   light shadow band just past the terminator (+ its edge tone)
    _ShadowColorN  / _ShadowFadeColorN    deep shadow (+ its edge tone)
    _SpecularColorN                       specular tint
    _OutlineColorN                        outline tint (multiplies the darkened diffuse)
    _ToonSpecularN / _SpecularRangeN      specular edge softness / highlight size
    _MatCapColorBurstN / _MatCapAlphaBurstN  matcap colour multiplier / blend weight
    _AlbedoSmoothness                     softness of the light/shadow edge
(slot 1 has no number suffix). This script bakes them into one 256x8 texture:

    rows 0-4  diffuse ramp per slot; U = light value, lit above 0.5
              U 0.00-0.25 shadow | 0.25 shadow-fade edge | 0.25-0.50 shallow | 0.50 shallow-fade edge | lit
    row 5     RGB specular colour per slot (U = slot/5 .. (slot+1)/5), A = _ToonSpecular x 4
    row 6     RGB outline colour / 2 per slot (same layout),           A = _SpecularRange / 4
    row 7     A only, 10 bins: _MatCapColorBurst / 4 for slots 1-5, then _MatCapAlphaBurst / 4 for slots 1-5

Colours are read as sRGB by Source; the numbers live in alpha, which is always read linear.
It also prints the material-wide values as ZZZ proxy keys to paste into the VMT.

Usage:
    python tools/zzz_ramp_from_json.py MAT_Anbi_Body_UI.json body_ramp.vtf
    python tools/zzz_ramp_from_json.py "Anby - Default.zip" body_ramp.vtf --member MAT_Anbi_Body_UI.json
    python tools/zzz_ramp_from_json.py ... --print       (also print the slot colours)
    python tools/zzz_ramp_from_json.py ... --soft 0.2 --edge 0.2    (smoother still)
    python tools/zzz_ramp_from_json.py ... --game        (the game's crisp bands and dark edge stripes)

Colours are written as they appear in the JSON (Unity gamma space) and read as sRGB by Source.
"""
import argparse
import json
import os
import struct
import zipfile

WIDTH, HEIGHT = 256, 8
SLOTS = 5
# Defaults the NapAvatar shader uses for unused slots (as seen in the JSONs)
DEFAULTS = {
    "_ShallowColor": (0.8, 0.8, 0.8), "_ShallowFadeColor": (0.8, 0.8, 0.8),
    "_ShadowColor": (0.6, 0.6, 0.6), "_ShadowFadeColor": (0.6, 0.6, 0.6),
    "_SpecularColor": (1.0, 1.0, 1.0), "_OutlineColor": (1.0, 1.0, 1.0),
}
# Per-slot numbers. Defaults reproduce the shader's look without a JSON (not game defaults).
FLOAT_DEFAULTS = {
    "_ToonSpecular": 0.05, "_SpecularRange": 1.0,
    "_MatCapColorBurst": 1.0, "_MatCapAlphaBurst": 1.0,
}


def load_material(path, member=None):
    if zipfile.is_zipfile(path):
        z = zipfile.ZipFile(path)
        names = [n for n in z.namelist() if n.lower().endswith(".json")]
        if not member:
            raise SystemExit("zip given: pass --member, one of:\n  " + "\n  ".join(names))
        match = [n for n in names if n.endswith(member)]
        if not match:
            raise SystemExit(f"{member} not found in zip")
        return json.loads(z.read(match[0]))
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def slot_color(colors, name, slot):
    key = name if slot == 0 else f"{name}{slot + 1}"
    c = colors.get(key)
    if c is None:
        return DEFAULTS[name]
    return (c["r"], c["g"], c["b"])


def slot_float(floats, name, slot):
    key = name if slot == 0 else f"{name}{slot + 1}"
    return float(floats.get(key, FLOAT_DEFAULTS[name]))


def lerp(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def smooth(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def ramp_color(u, shadow, shadow_fade, shallow, shallow_fade, soft):
    lit = (1.0, 1.0, 1.0)
    # Deep shadow darkens toward its edge tone just before the 0.25 edge
    shadow_side = lerp(shadow, shadow_fade, smooth((u - (0.25 - soft)) / soft))
    # Shallow band darkens toward its edge tone just before the 0.5 terminator
    shallow_side = lerp(shallow, shallow_fade, smooth((u - 0.4) / 0.1))
    # Both edges are centred on 0.25 / 0.5 and `soft` wide
    mid = lerp(shadow_side, shallow_side, smooth((u - (0.25 - soft / 2)) / soft))
    return lerp(mid, lit, smooth((u - (0.5 - soft / 2)) / soft))


def to_byte(v):
    return max(0, min(255, int(round(v * 255))))


def proxy_keys(mat):
    """Material-wide JSON values as ZZZ proxy keys (see the VMT templates)."""
    shader = mat["m_Shader"]["Name"]
    floats = mat["m_SavedProperties"]["m_Floats"]
    keys = {}
    if "Face" in shader:
        if "_NoseLineHoriDisp" in floats:
            keys["noselineside"] = floats["_NoseLineHoriDisp"]
        if "_NoseLineLkDnDisp" in floats:
            keys["noselinedown"] = floats["_NoseLineLkDnDisp"]
    else:
        if "_SpecIntensity" in floats:
            keys["specstrength"] = round(floats["_SpecIntensity"] * 10, 3)   # 0.1 (body) = 1
        if "_MatCap" in floats:
            keys["matcapstrength"] = 1 if floats["_MatCap"] else 0
        if floats.get("_MatCap"):
            keys["matcapmode"] = int(floats.get("_MatCapBlendMode", 2))
    if "_FresnelWidth" in floats:
        keys["rimwidth"] = floats["_FresnelWidth"]
    return keys


# Look of the band edges. The game's own values (_AlbedoSmoothness, full-strength "fade" edge tones)
# give crisp bands with thin dark stripes, which read as hard, glossy banding in GMod. The defaults
# here are softer: wider transitions and mostly-faded edge tones. `--game` restores the game's look.
SMOOTH_SOFT = 0.12   # transition width in light value (game: _AlbedoSmoothness, 0.05)
SMOOTH_EDGE = 0.4    # 0 = no edge tone, 1 = the game's full edge tone


def build(mat, print_slots=False, soft=None, edge=None):
    """soft / edge: see SMOOTH_SOFT / SMOOTH_EDGE. Pass soft=0 and edge=1 for the game's own look
    (soft 0 means: use the material's _AlbedoSmoothness)."""
    props = mat["m_SavedProperties"]
    colors = props["m_Colors"]
    floats = props["m_Floats"]
    game_soft = max(float(floats.get("_AlbedoSmoothness", 0.05)), 0.01)
    soft = SMOOTH_SOFT if soft is None else (game_soft if soft == 0 else max(soft, 0.01))
    edge = SMOOTH_EDGE if edge is None else edge

    rows = []
    slots = []
    for s in range(SLOTS):
        c = {n: slot_color(colors, n, s) for n in DEFAULTS}
        c.update({n: slot_float(floats, n, s) for n in FLOAT_DEFAULTS})
        slots.append(c)
        # Pull each edge tone toward its band's own colour by `edge`
        shadow_fade = lerp(c["_ShadowColor"], c["_ShadowFadeColor"], edge)
        shallow_fade = lerp(c["_ShallowColor"], c["_ShallowFadeColor"], edge)
        rows.append([ramp_color(x / (WIDTH - 1), c["_ShadowColor"], shadow_fade,
                                c["_ShallowColor"], shallow_fade, soft) for x in range(WIDTH)])

    def per_slot_row(name):
        return [slots[min(SLOTS - 1, x * SLOTS // WIDTH)][name] for x in range(WIDTH)]

    def per_slot(name, scale):
        return [slots[min(SLOTS - 1, x * SLOTS // WIDTH)][name] * scale for x in range(WIDTH)]

    # Rows 0-4 alpha is unused (1)
    rows = [[(r, g, b, 1.0) for (r, g, b) in row] for row in rows]
    rows.append([rgb + (a,) for rgb, a in zip(per_slot_row("_SpecularColor"), per_slot("_ToonSpecular", 4.0))])
    # Outline tints can exceed 1 (e.g. hair 1.41 blue); store /2 so the shader multiplies by 2
    rows.append([tuple(v / 2 for v in c) + (a,)
                 for c, a in zip(per_slot_row("_OutlineColor"), per_slot("_SpecularRange", 0.25))])
    bins = [slots[s]["_MatCapColorBurst"] / 4 for s in range(SLOTS)] +            [slots[s]["_MatCapAlphaBurst"] / 4 for s in range(SLOTS)]
    rows.append([(0.0, 0.0, 0.0, bins[min(9, x * 10 // WIDTH)]) for x in range(WIDTH)])

    if print_slots:
        print(f"shader {mat['m_Shader']['Name']}  _MaterialNum {floats.get('_MaterialNum')}  "
              f"_SkinMatId {floats.get('_SkinMatId')}  _AlbedoSmoothness {soft}")
        for s, c in enumerate(slots):
            print(f"  slot {s + 1} (LightMap.R ~{1 - s / 4:.2f}): " +
                  "  ".join(f"{n[1:]}={tuple(round(v, 2) for v in c[n])}" for n in DEFAULTS) + "  " +
                  "  ".join(f"{n[1:]}={round(c[n], 3)}" for n in FLOAT_DEFAULTS))
        print("VMT proxy keys:")
        for k, v in proxy_keys(mat).items():
            print(f"    {k:<16}{v}")
    return rows


def write_vtf(rows, dst, quiet=False):
    data = bytearray()
    for row in rows:
        for (r, g, b, a) in row:
            data += bytes([to_byte(b), to_byte(g), to_byte(r), to_byte(a)])   # BGRA8888
    flags = 0x0004 | 0x0008 | 0x0100 | 0x0200   # clamp S/T, no mip, no LOD
    header = bytearray(80)
    struct.pack_into('<4sIIIHHIHH4xfff4xfiBiBBH', header, 0, b'VTF\0', 7, 2, 80, WIDTH, HEIGHT, flags,
                     1, 0, 1.0, 1.0, 1.0, 1.0, 12, 1, -1, 0, 0, 1)
    os.makedirs(os.path.dirname(os.path.abspath(dst)), exist_ok=True)
    with open(dst, "wb") as f:
        f.write(header + data)
    if not quiet:
        print(f"wrote {dst}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", help="material JSON, or a zip containing it")
    ap.add_argument("output", help="output .vtf")
    ap.add_argument("--member", help="JSON file name inside the zip")
    ap.add_argument("--print", action="store_true", help="print the slot values and VMT proxy keys")
    ap.add_argument("--soft", type=float, default=None,
                    help=f"band edge width in light value (default {SMOOTH_SOFT}; 0 = the game's _AlbedoSmoothness)")
    ap.add_argument("--edge", type=float, default=None,
                    help=f"strength of the dark edge tones, 0-1 (default {SMOOTH_EDGE}; 1 = the game's)")
    ap.add_argument("--game", action="store_true", help="the game's crisp look: --soft 0 --edge 1")
    a = ap.parse_args()
    soft, edge = (0, 1.0) if a.game else (a.soft, a.edge)
    write_vtf(build(load_material(a.input, a.member), a.print, soft, edge), a.output)
