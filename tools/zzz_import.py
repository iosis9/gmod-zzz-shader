"""
Import a ZZZ character from a game export (the zip with Materials/*.json and Textures/*.png) into a
GMod materials folder: every texture converted to VTF, ramps and emission maps baked, and a ZZZ VMT
written for each material with the values from its JSON.

    python tools/zzz_import.py "Harumasa - Default.zip" <garrysmod>/addons/<addon>/materials/<path> --dry-run
    python tools/zzz_import.py "Harumasa - Default.zip" <same folder> --rename body_1=body,body_2=body2

Per game material (MAT_<Character>_<Part>_UI.json), by its shader:
  NapAvatarUI / NapAvatarUITransparent   body/hair/weapon VMT (zzz_body_ps30); see-through materials
                                          get alphamode 2 + $alpha_blend 1
  NapAvatarUIFace                         face VMT (zzz_face_ps30) with the face shadow map
  NapAvatarUIEye, NapStencilShadowCaster  skipped (no eye shader; hair shadow is built in)

Textures (named in the JSON's m_TexEnvs):
  _MainTex -> diffuse (sRGB)   _OtherDataTex -> light map   _OtherDataTex2 -> material map
  _LightTex -> normal map (green flipped for Source, blue set to 255: the game stores ~0.5 there,
               which the shader would read as half occlusion) -- or the face shadow map on faces
  _MatCapTex -> matcap, when _MatCap is on
Converted textures keep their game names, lowercased (harumasa_body_map1_d.vtf). Generated files are
named after the material: <part>_ramp.vtf, <part>_e.vtf and <part>.vmt, where <part> is the game
part name (body_1) or its --rename target (body).

The VMTs reference textures by the folder's path under materials/ (or --vmt-path). Existing files are
skipped unless --overwrite. Model materials in the folder that get no VMT are listed at the end: every
material on a model must use the ZZZ shader.
"""
import argparse
import io
import json
import os
import re
import sys
import zipfile

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import zzz_emission_from_json as emission     # noqa: E402
import zzz_ramp_from_json as ramp             # noqa: E402
from png_to_vtf import write_vtf              # noqa: E402

BODY_SHADERS = ("NapAvatarUI", "NapAvatarUITransparent")
FACE_SHADER = "NapAvatarUIFace"


class Source:
    """The game export: a zip or a folder, files looked up by name anywhere inside."""

    def __init__(self, path):
        self.path = path
        if zipfile.is_zipfile(path):
            self.zip = zipfile.ZipFile(path)
            self.names = self.zip.namelist()
        else:
            self.zip = None
            self.names = [os.path.relpath(os.path.join(d, f), path).replace("\\", "/")
                          for d, _, fs in os.walk(path) for f in fs]

    def find(self, basename):
        hits = [n for n in self.names if n.split("/")[-1].lower() == basename.lower()]
        return hits[0] if hits else None

    def read(self, name):
        if self.zip:
            return self.zip.read(name)
        with open(os.path.join(self.path, name), "rb") as f:
            return f.read()

    def image(self, texture):
        name = self.find(texture + ".png")
        if not name:
            raise FileNotFoundError(texture + ".png")
        return Image.open(io.BytesIO(self.read(name)))

    def materials(self):
        out = []
        for n in sorted(self.names):
            if n.lower().endswith(".json") and "/materials/" in "/" + n.lower():
                out.append((n.split("/")[-1], json.loads(self.read(n))))
        return out


def part_name(json_name):
    """MAT_Harumasa_Body_1_UI.json -> body_1"""
    stem = re.sub(r"\.json$", "", json_name, flags=re.I)
    stem = re.sub(r"_UI$", "", stem, flags=re.I)
    tokens = stem.split("_")
    if tokens and tokens[0].upper() == "MAT":
        tokens = tokens[1:]
    if len(tokens) > 1:
        tokens = tokens[1:]          # drop the character name
    return "_".join(tokens).lower()


def tex_env(mat, key):
    t = mat["m_SavedProperties"]["m_TexEnvs"].get(key, {}).get("m_Texture", {})
    return t.get("Name") or None


def normal_for_source(img):
    a = np.array(img.convert("RGBA"))
    a[..., 1] = 255 - a[..., 1]     # Unity (OpenGL) -> Source (DirectX) green
    a[..., 2] = 255                 # blue: no occlusion
    return Image.fromarray(a)


class Plan:
    def __init__(self, out_dir, vmt_path, overwrite, dry_run):
        self.out_dir, self.vmt_path, self.overwrite, self.dry_run = out_dir, vmt_path, overwrite, dry_run
        self.done = {}
        self.log = []

    def ref(self, name):
        return f"{self.vmt_path}/{name}"

    def _target(self, name, ext):
        path = os.path.join(self.out_dir, name + ext)
        if os.path.exists(path) and not self.overwrite:
            self.log.append(f"  exists, skipped   {name}{ext}")
            return None
        return path

    def texture(self, name, make_image, clamp=False):
        """Convert once per output name; make_image() is only called when the file is written."""
        name = name.lower()
        if name in self.done:
            return self.done[name]
        path = self._target(name, ".vtf")
        if path:
            if self.dry_run:
                self.log.append(f"  would write       {name}.vtf")
            else:
                write_vtf(make_image(), path, clamp=clamp, quiet=True)
                self.log.append(f"  wrote             {name}.vtf")
        self.done[name] = self.ref(name)
        return self.done[name]

    def raw_vtf(self, name, write):
        """Generated VTF (ramp, emission): write(path) does the work."""
        name = name.lower()
        path = self._target(name, ".vtf")
        if path:
            if self.dry_run:
                self.log.append(f"  would write       {name}.vtf")
            else:
                write(path)
                self.log.append(f"  wrote             {name}.vtf")
        return self.ref(name)

    def vmt(self, name, text):
        path = self._target(name, ".vmt")
        if path:
            if self.dry_run:
                self.log.append(f"  would write       {name}.vmt")
            else:
                with open(path, "w", encoding="utf-8", newline="\r\n") as f:
                    f.write(text)
                self.log.append(f"  wrote             {name}.vmt")


def vmt_text(shader, game_json, textures, keys, extra):
    lines = [f"// Generated by tools/zzz_import.py from {game_json}", "screenspace_general_8tex", "{",
             f'\t$pixshader            "{shader}"',
             '\t$vertexshader         "zzz_body_vs30"', ""]
    for k, v in textures:
        lines.append(f'\t{k:<21} "{v}"')
    lines.append("")
    for k, v in extra:
        lines.append(f"\t{k:<21} {v}")
    lines += ["\t$model                1", "\t$cull                 1", "\t$vertexnormal         1", "",
              "\tProxies", "\t{", "\t\tZZZ", "\t\t{"]
    for k, v in keys:
        lines.append(f"\t\t\t{k:<15} {v}")
    lines += ["\t\t}", "\t}", "}", ""]
    return "\n".join(lines)


def import_material(src, plan, json_name, mat, part):
    shader = mat["m_Shader"]["Name"].split("/")[-1]
    floats = mat["m_SavedProperties"]["m_Floats"]
    keys = list(ramp.proxy_keys(mat).items())

    if shader == FACE_SHADER:
        diffuse, facemap = tex_env(mat, "_MainTex"), tex_env(mat, "_LightTex")
        textures = [("$basetexture", plan.texture(diffuse, lambda: src.image(diffuse)))]
        if facemap:
            textures.append(("$texture1", plan.texture(facemap, lambda: src.image(facemap), clamp=True)))
        rows = ramp.build(mat)
        textures.append(("$texture4", plan.raw_vtf(part + "_ramp", lambda p: ramp.write_vtf(rows, p, quiet=True))))
        keys = [("ramprow", 0), ("rimstrength", 0)] + keys
        plan.vmt(part, vmt_text("zzz_face_ps30", json_name, textures, keys, [("$linearread_texture1", 1)]))
        return

    d, m, n, a = (tex_env(mat, k) for k in ("_MainTex", "_OtherDataTex", "_LightTex", "_OtherDataTex2"))
    textures = [("$basetexture", plan.texture(d, lambda: src.image(d)))]
    if m:
        textures.append(("$texture1", plan.texture(m, lambda: src.image(m))))
    if n:
        textures.append(("$texture2", plan.texture(n, lambda: normal_for_source(src.image(n)))))
    if a:
        textures.append(("$texture3", plan.texture(a, lambda: src.image(a))))

    rows = ramp.build(mat)
    textures.append(("$texture4", plan.raw_vtf(part + "_ramp", lambda p: ramp.write_vtf(rows, p, quiet=True))))

    if floats.get("_MatCap"):
        mc = tex_env(mat, "_MatCapTex")
        if mc:
            textures.append(("$texture5", plan.texture(mc, lambda: src.image(mc), clamp=True)))

    # Emission: needs the diffuse, light map and material map under one name prefix
    prefix = d[:-2] if d and d.endswith("_D") else None
    if prefix and m == prefix + "_M" and a == prefix + "_A":
        result, _ = emission.build(src.path, mat, prefix)
        if result:
            img, brightest, _, _ = result
            textures.append(("$texture7", plan.raw_vtf(part + "_e", lambda p: write_vtf(img, p, mips=False, quiet=True))))
            keys.append(("emissionscale", f"{brightest:.2f}"))

    extra = [("$linearread_texture1", 1), ("$linearread_texture2", 1), ("$linearread_texture3", 1)]
    if shader == "NapAvatarUITransparent":
        keys.append(("alphamode", 2))
        extra.append(("$alpha_blend", 1))
    plan.vmt(part, vmt_text("zzz_body_ps30", json_name, textures, keys, extra))


def vmt_path_for(out_dir):
    parts = os.path.abspath(out_dir).replace("\\", "/").split("/")
    lower = [p.lower() for p in parts]
    if "materials" not in lower:
        return None
    i = len(lower) - 1 - lower[::-1].index("materials")
    return "/".join(parts[i + 1:]).lower()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", help="game export zip, or a folder with the JSONs and PNGs")
    ap.add_argument("output", help="materials folder to write into (usually <addon>/materials/<path>)")
    ap.add_argument("--rename", default="", help="game part -> model material name, e.g. body_1=body,body_2=body2")
    ap.add_argument("--vmt-path", help="texture path used in the VMTs (default: the output folder under materials/)")
    ap.add_argument("--overwrite", action="store_true", help="replace existing files")
    ap.add_argument("--dry-run", action="store_true", help="only print what would be written")
    a = ap.parse_args()

    vmt_path = a.vmt_path or vmt_path_for(a.output)
    if not vmt_path:
        raise SystemExit("the output folder isn't under a materials/ folder: pass --vmt-path")
    rename = dict(pair.split("=", 1) for pair in a.rename.split(",") if "=" in pair)
    rename = {k.strip().lower(): v.strip() for k, v in rename.items()}

    src = Source(a.input)
    if not a.dry_run:
        os.makedirs(a.output, exist_ok=True)
    plan = Plan(a.output, vmt_path, a.overwrite, a.dry_run)

    written = set()
    for json_name, mat in src.materials():
        shader = mat.get("m_Shader", {}).get("Name", "").split("/")[-1]
        game_part = part_name(json_name)
        part = rename.get(game_part, game_part)
        if shader in BODY_SHADERS or shader == FACE_SHADER:
            plan.log.append(f"{json_name} ({shader}) -> {part}.vmt")
            try:
                import_material(src, plan, json_name, mat, part)
                written.add(part.lower())
            except FileNotFoundError as e:
                plan.log.append(f"  missing texture {e}: skipped")
        else:
            plan.log.append(f"{json_name} ({shader}): skipped, not a body or face material")

    print("\n".join(plan.log))
    unused = [k for k in rename if k not in {part_name(j) for j, _ in src.materials()}]
    if unused:
        print(f"\n--rename names not found in the export: {', '.join(unused)}")
    if os.path.isdir(a.output):
        others = sorted(os.path.splitext(f)[0] for f in os.listdir(a.output)
                        if f.lower().endswith(".vmt") and os.path.splitext(f)[0].lower() not in written)
        if others:
            print(f"\nModel materials here without a generated VMT: {', '.join(others)}")
            print("Every material on the model must use the ZZZ shader: map them with --rename, or convert them by hand.")


if __name__ == "__main__":
    main()
