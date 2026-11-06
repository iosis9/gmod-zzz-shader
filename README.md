# ZZZ Shader for Garry's Mod

> This project uses AI generated code.

A Zenless Zone Zero style toon shader for player models and NPCs in Garry's Mod. It uses the game's own texture layout and reacts to map lighting, fog, flashlights and lamps.

## Install

Download `zzz_shader` from [Releases](../../releases), extract it into `garrysmod/addons/` and restart GMod.

From a clone of this repository, run `install_to_gmod.bat` instead. It looks for GMod in Steam's default library; for another location, pass the `garrysmod` folder: `install_to_gmod.bat "D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod"`.

## Set up a model

Every material on the model must use this shader. Mixing in normal (VertexLitGeneric) materials breaks the rest of the model.

### Import from a game export

`tools/zzz_import.py` does everything below in one step from a character export (the zip with `Materials/*.json` and `Textures/*.png`): converts the textures, bakes ramps and glow maps, and writes a VMT per material with the game's values.

```
python tools/zzz_import.py "Harumasa - Default.zip" "<addon>/materials/<model path>" --rename body_1=body,body_2=body2 --dry-run
```

- Game materials are named after their part (`MAT_Harumasa_Body_1_UI.json` → `body_1`). Use `--rename` to match the model's own material names.
- `--dry-run` lists what would be written. Existing files are kept unless you add `--overwrite`.
- It lists the model's materials it couldn't cover. Eyes and other extra materials still need converting by hand.

Requires Python with Pillow and numpy.

### Body, hair and other parts

Copy `addon/materials/models/zzz/zzz_body_template.vmt` over the model's material and set its textures:

| VMT slot | Texture |
| :-- | :-- |
| `$basetexture` | `_D` diffuse |
| `$texture1` | `_M` light map |
| `$texture2` | `_N` normal map |
| `$texture3` | `_A` material map |
| `$texture4` | toon ramp (see below) |
| `$texture5` | matcap (optional) |
| `$texture7` | `_E` emission (optional) |

Only `$basetexture` is required. Missing textures fall back to neutral defaults.

### Face

Copy `zzz_face_template.vmt` instead. Set `$basetexture` to the face diffuse and `$texture1` to the face shadow map (for female characters, `Female_Face_Lightmap.png`). Convert the map first:

```
python tools/png_to_vtf.py Female_Face_Lightmap.png face_lightmap.vtf --clamp
```

If the face shadow falls on the wrong side, set `flipfacemap 1`. If it doesn't follow the head, set `headforward` / `headright` and run `zzz_face_recalibrate`.

### Toon ramps

Each material needs a ramp baked from its game material JSON (`MAT_<Character>_<Part>_UI.json`):

```
python tools/zzz_ramp_from_json.py "Character.zip" body_ramp.vtf --member MAT_Anbi_Body_UI.json --print
```

Make one ramp each for body, hair, face and weapon, and point that material's `$texture4` at it. `--print` also lists proxy keys to copy into the VMT. Add `--soft 0.2 --edge 0.2` for softer shading bands, or `--game` for the game's sharper ones.

### Glow (emission)

Glowing parts (light strips, screens) are baked into an emission texture from the same JSON:

```
python tools/zzz_emission_from_json.py "Character.zip" weapon_e.vtf --member MAT_Harumasa_Weapon_UI.json --textures Harumasa_Weapon
```

`--textures` is the texture name prefix (`<prefix>_D.png`, `_M.png` and `_A.png` are read). Set `$texture7` to the result and `emissionscale` to the value it prints. Materials that don't glow are skipped.

### Transparency

| Part | Settings |
| :-- | :-- |
| Cutouts (lashes, strands) | `alphamode 1` |
| See-through parts (glass) | `alphamode 2` and `$alpha_blend 1` |

## Material settings

Set these in the material's `ZZZ` proxy block. All are optional.

| Key | Default | Effect |
| :-- | :-- | :-- |
| `intensity` | 1 | brightness |
| `shadowstrength` | 1 | shadow colour amount (0 = no shadows) |
| `maxlight` | from `zzz_max_light` | brightness cap (0 = off) |
| `specstrength` | 1 | highlight strength |
| `specpower` | from `zzz_spec_power` | highlight size (higher = smaller) |
| `matcapstrength` | 1 | matcap strength |
| `matcapmode` | 0 | matcap blend: 0 replace, 1 add, 2 multiply |
| `rimstrength` | 1 | rim light strength |
| `rimwidth` | 3.5 | rim light thickness (higher = thinner) |
| `emissionscale` | 1 | glow strength |
| `alphamode` | 0 | 0 opaque, 1 cutout, 2 see-through |
| `outline` | 1 | 0 = no outline |
| `colortint`, `emissiontint` | `[1 1 1]` | colour multipliers |

Face only:

| Key | Default | Effect |
| :-- | :-- | :-- |
| `ramprow` | 0 | which ramp row the face uses |
| `faceshadow` | 1 | face shadow map strength (0 = normal shading) |
| `noseline` | 1 | nose line strength |
| `flipfacemap` | 0 | 1 = mirror the face shadow |
| `headbone` | `ValveBiped.Bip01_Head1` | bone the face shadow follows |
| `headforward`, `headright` | auto | head bone axes (`x`, `-x`, `y`, `-y`, `z`, `-z`) |

## Console variables

| Variable | Default | Effect |
| :-- | :-- | :-- |
| `zzz_intensity` | 1 | overall brightness |
| `zzz_ambient_scale` | 1 | ambient light strength |
| `zzz_max_light` | 1 | brightness cap (1 = never brighter than the texture, 0 = off) |
| `zzz_shadow_strength` | 1 | shadow colour amount |
| `zzz_cel_softness` | 0.03 | shadow edge softness |
| `zzz_cel_threshold` | 0.5 | where the shadow edge sits |
| `zzz_spec_strength` | 1 | highlight strength |
| `zzz_spec_power` | 16 | highlight size (higher = smaller) |
| `zzz_rim_strength` | 1 | rim light strength |
| `zzz_outline` | 1 | outlines on/off |
| `zzz_outline_width` | 1 | outline thickness |
| `zzz_outline_darkness` | 0.35 | outline brightness as a fraction of the texture colour (lower = darker) |
| `zzz_outline_max_distance` | 100 | distance after which outlines stop growing |
| `zzz_outline_min_scale` | 0.5 | how thin outlines can get far away (0 = no limit) |
| `zzz_flashlight` | 1 | flashlights and lamps light ZZZ models |
| `zzz_flashlight_strength` | 1 | flashlight brightness |
| `zzz_flashlight_cookie` | 1 | 1 = flashlight texture shape, 0 = plain circle |
| `zzz_light_override` | 0 | extra key light: 0 off, 1 manual, 2 map sun |
| `zzz_light_yaw`, `zzz_light_pitch` | 45, 45 | manual key light direction |
| `zzz_light_strength` | 0.8 | manual key light strength |
| `zzz_hair_shadow` | 0 | hair shadow on the face (experimental) |

## Troubleshooting

| Problem | Fix |
| :-- | :-- |
| Model invisible, only the outline shows | The shaders aren't installed. Run the installer again and restart GMod. |
| Model solid red with yellow lines | Some of its materials don't use this shader. Convert them all. |
| Too bright in sunlight | Lower `zzz_max_light`, or set `maxlight` on that material. |
| Shader changes don't show | Run `mat_reloadallmaterials`. Changed shader files need a restart. |

## Limitations

- Flashlights and lamps don't cast shadows on ZZZ models, and all beams use the same round shape.
- Outlines have a uniform width and can split on hard edges.
- Not supported on native Linux. Use Proton.

## Building the shaders

Only needed if you change the `.hlsl` files; compiled shaders are included. Put these in `shaders/`:

- `ShaderCompile.exe`, built from [SCell555/ShaderCompile](https://github.com/SCell555/ShaderCompile)
- `common_fxc.h`, `common_hlsl_cpp_consts.h`, `common_pragmas.h`, `common_ps_fxc.h` and `common_vs_fxc.h` from `src/materialsystem/stdshaders` in [ValveSoftware/source-sdk-2013](https://github.com/ValveSoftware/source-sdk-2013)

Then run `shaders\build_shaders.bat` and the installer. `python generate_common_assets.py` rebuilds the default textures.

## Credits

- ZZZ texture layout: [leotorrez's guide](https://leotorrez.github.io/modding/guides/zzz-textures)
- [Kythera's ZZZ Blender shader](https://github.com/Jideeh1/Kytheras-ZZZ-Shader)
- [meetric1's GMod shader guide](https://github.com/meetric1/gmod_shader_guide)
- ExoPBR (Workshop 3625705812): skinning layout, lighting and depth techniques

## License

MIT, see [LICENSE](LICENSE). Character models, textures and game data used with this shader belong to their owners and are not part of this repository.
