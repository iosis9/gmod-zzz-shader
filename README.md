# ZZZ Shader for Garry's Mod

> This project uses AI generated code.

A Zenless Zone Zero–style NPR character shader for Garry's Mod, built on `screenspace_general_8tex` with custom SM3.0 shaders. It uses the real ZZZ texture layout and takes its lighting from the engine, so the model reacts to the map's lights and fog.

Built from these references:
- ZZZ texture layout: <https://leotorrez.github.io/modding/guides/zzz-textures>
- Kythera's ZZZ Blender shader (outline = darkened diffuse, separate face/body shaders): <https://github.com/Jideeh1/Kytheras-ZZZ-Shader>
- `screenspace_general` model rendering: <https://github.com/meetric1/gmod_shader_guide>
- Source SDK 2013 shader headers: <https://github.com/ValveSoftware/source-sdk-2013>
- ExoPBR (Workshop 3625705812) for the skinning layout, the lighting "populator" and the depth fix

## Layout

```
shaders/
  zzz_body_vs30.hlsl      skinning (3 bones, compressed normal+tangent), flexes, fog, light attenuation
  zzz_body_ps30.hlsl      cel ramp, matcap, specular, rim, emission
  zzz_face_ps30.hlsl      face shadow from the face lightmap + head direction
  zzz_lighting_ps.h       shared engine-light gathering, ramp lookup, fog
  zzz_outline_vs30.hlsl   inverted hull, roughly constant screen width
  zzz_outline_ps30.hlsl   darkened diffuse
  build_shaders.bat       compiles every zzz_*_vs30 / zzz_*_ps30 into addon/shaders/fxc
addon/
  lua/autorun/client/zzz_lighting_proxy.lua   "ZZZ" material proxy, lighting, depth, outlines
  materials/models/zzz/zzz_body_template.vmt  material template
  materials/models/zzz/common/                ramp, matcaps, rim curve, neutral fallbacks
generate_common_assets.py                     regenerates models/zzz/common/*.vtf
install_to_gmod.bat                           copies the addon into your GMod folder
```

## Textures

| VMT slot | ZZZ map | Channels |
| :-- | :-- | :-- |
| `$basetexture` | `_D` Diffuse (sRGB) | RGB albedo. A is used only with `alphamode 1`. |
| `$texture1` | `_M` LightMap | **R** material slot (levels 1.0 / 0.69 / 0.5 / 0.29 / 0 → slots 1–5), **G** metallic (matcap), **B** specular amount (0 = no highlight; on the hair it's the painted shine marks) |
| `$texture2` | `_N` NormalMap | **RG** tangent normal (Z is rebuilt), **B** occlusion |
| `$texture3` | `_A` MaterialMap | **R** transparency (`alphamode 2`), **G** tints the specular by albedo, **B** specular mask |
| `$texture4` | toon ramp | 256×8: rows 0–4 = the 5 slot ramps, rows 5–7 = per-slot specular colour, outline colour, specular softness/size and matcap bursts. Bake it from the game JSON (below). |
| `$texture5` | matcap | RGB colour, A blend weight, masked by LightMap.G. The game's own (e.g. `Eff_MatCap_007.png`, converted with `png_to_vtf.py --clamp`) or `metal_matcap` / `_gold` / `_chrome` |
| `$texture6` | unused | the rim is a fresnel power now (`rimwidth`) |
| `$texture7` | `_E` emission (optional) | RGB colour, A mask |

`$texture1`–`$texture3` must be read linearly (`$linearread_textureN 1`). The template does this, and so does the proxy. Missing slots fall back to neutral textures.

### Ramps from the game's material JSON

ZZZ doesn't use a ramp texture. Each material (`MAT_<Char>_<Part>_UI.json` in a raw FBX export) defines up to 5 **material slots**, and LightMap.R picks one per pixel. The slots run in reverse: R 1.0 → slot 1, 0.69 → slot 2, 0.5 → slot 3 (usually skin, `_SkinMatId`), 0.29 → slot 4, 0 → slot 5. Each slot has its own `_ShallowColor` (light shadow band), `_ShadowColor` (deep shadow), their `Fade` edge tones, `_SpecularColor` and `_OutlineColor`.

`tools/zzz_ramp_from_json.py` bakes all of that into one ramp per material:

```
python tools/zzz_ramp_from_json.py "Anby - Default.zip" body_ramp.vtf --member MAT_Anbi_Body_UI.json --print
```

The bands are softer than the game's by default: the game's thin dark "fade" stripes at the band edges look like hard, glossy banding in GMod. Tune it with `--soft` (edge width, default 0.12) and `--edge` (strength of the dark edge tones, default 0.4); `--soft 0.2 --edge 0.2` is smoother still, and `--game` gives the game's crisp bands.

`--print` also lists the material-wide values as proxy keys to paste into the VMT (`specstrength`, `matcapstrength`, `matcapmode`, `rimwidth`, and on faces `noselineside` / `noselinedown`).

Point that material's `$texture4` at the result. Use one ramp each for body, hair and face, since each JSON has different slot colours. On the face, `ramprow` picks the slot (the face JSON's slot 1 is its skin, so it's row 0). The shared `models/zzz/common/toon_ramp` holds the shader's grey default slots.

## Materials

Copy `zzz_body_template.vmt`, point the textures at the model's maps, and keep `$model 1`, `$cull 1` and `$vertexnormal 1`. Per-material settings live in the `ZZZ` proxy block:

| key | default | meaning |
| :-- | :-- | :-- |
| `intensity` | 1 | light multiplier |
| `shadowstrength` | 1 | 0 = no cel shadows |
| `rimstrength`, `specstrength`, `matcapstrength`, `emissionscale` | 1 | per-feature multipliers. `specstrength` = game `_SpecIntensity` × 10 (body 1, hair 2) |
| `specpower` | unset | highlight size: higher = smaller. Unset uses `zzz_spec_power` |
| `maxlight` | unset | soft cap on how bright the light on this material can get. 1 = never brighter than its texture. 0 = off for this material. Unset uses `zzz_max_light` (default 1) |
| `matcapmode` | 0 | 0 replaces the shading, 1 adds, 2 multiplies. ZZZ bodies use 2 (`_MatCapBlendMode`) |
| `rimwidth` | 3.5 | rim = (1 − N·V)^width, the game's `_FresnelWidth`. Higher = thinner rim |
| `alphamode` | 0 | 0 opaque, 1 diffuse alpha cutout, 2 MaterialMap.R |
| `outline` | 1 | 0 disables the outline for this material |
| `colortint`, `emissiontint` | `[1 1 1]` | colour multipliers |

Transparent parts, such as glasses or Anby's backpack glass, need `alphamode 2` plus `$alpha_blend 1` in the VMT.

## Faces

Faces use `zzz_face_template.vmt` and the `zzz_face_ps30` shader. A ZZZ face isn't shaded from its normals. It uses a shared **face shadow map** (for Anby, `Female_Face_Lightmap.png`): R holds the light angle at which each texel turns lit, B is the nose line and A masks where the face map applies. As in ZZZ, the nose line only appears when the camera is off to the side or above the face. The Lua proxy tracks the head bone so the shadow follows the head.

1. Convert the map: `python tools/png_to_vtf.py Female_Face_Lightmap.png <your materials>/face_lightmap.vtf --clamp`
2. Copy `zzz_face_template.vmt`, set `$basetexture` to the face diffuse and `$texture1` to the converted map.
3. In game, rotate a light around the head (`zzz_light_override 1` plus `zzz_light_yaw`):
   - If the shadow goes to the wrong side, set `flipfacemap 1`.
   - If it doesn't follow the head properly, set `headforward` / `headright` in the proxy block and run `zzz_face_recalibrate`.

Face proxy keys: `faceshadow`, `noseline` (strength, 1), `noselineside` (0.8522) / `noselinedown` (0.62) (the game's `_NoseLineHoriDisp` / `_NoseLineLkDnDisp`), `ramprow` (0–4), `rimwidth`, `headbone` (default `ValveBiped.Bip01_Head1`), `headforward`, `headright`, `flipfacemap`, plus the common `intensity`, `shadowstrength`, `rimstrength`, `alphamode`, `outline` and `colortint`.

### Hair shadow on the face

ZZZ draws a shifted copy of the fringe that shadows the face. Ported models don't have the game's dedicated `HairShadow` mesh, so the hair itself casts: it's shifted down, away from the light and slightly toward the camera, and wherever it lands in front of the face, the face is redrawn in its shadow tone. Back hair doesn't cast, because it's behind the face.

- Hair materials cast by default if their name contains "hair". Set `hairshadow 1` or `0` in a body material's proxy block to override.
- On a face material, `hairshadow` is how strongly it receives (default 1, 0 = never).
- It costs three extra draws of the model per frame. Turn it off with `zzz_hair_shadow 0` if you have many ZZZ characters on screen.

## Console variables

| cvar | default | |
| :-- | :-- | :-- |
| `zzz_intensity` | 1 | overall light |
| `zzz_ambient_scale` | 1 | ambient cube strength |
| `zzz_cel_softness` | 0.03 | shadow edge softness |
| `zzz_cel_threshold` | 0.5 | where the shadow edge sits |
| `zzz_shadow_strength` | 1 | ramp shadow colour amount |
| `zzz_rim_strength`, `zzz_spec_strength` | 1 | |
| `zzz_spec_power` | 16 | specular highlight size (higher = smaller, tighter) |
| `zzz_flashlight` | 1 | flashlights and projected textures (lamps, the player flashlight) light ZZZ models |
| `zzz_flashlight_strength` | 1 | their brightness on ZZZ models |
| `zzz_flashlight_cookie` | 1 | 1 = beam shaped by the standard flashlight texture, 0 = plain soft circle |
| `zzz_max_light` | 1 | soft cap on how bright the light on a model can get (1 = never brighter than its texture, 0 = off). Fixes models blowing out in sunlight without darkening shaded areas. A material's `maxlight` key overrides it |
| `zzz_light_override` | 0 | extra key light: 0 off, 1 manual, 2 map sun |
| `zzz_light_yaw`, `zzz_light_pitch`, `zzz_light_strength` | 45, 45, 0.8 | manual key light |
| `zzz_outline` | 1 | outlines on/off |
| `zzz_outline_width` | 1 | outline thickness |
| `zzz_outline_max_distance` | 100 | past this camera distance outlines stop growing and shrink with the model. Zoom is taken into account, so a zoomed-in camera counts as closer. |
| `zzz_outline_min_scale` | 0.5 | far away, outlines never get thinner on screen than this fraction of their close-up width (0 = no limit) |
| `zzz_outline_darkness` | 0.35 | outline = diffuse × this |
| `zzz_hair_shadow` | 0 | hair casts a shadow onto the face (experimental, off by default) |
| `zzz_hair_shadow_strength` | 1 | hair shadow opacity |
| `zzz_hair_shadow_offset` | 0.4 | how far the hair shadow shifts, in world units per game offset unit (the game's offsets are X 0.8, Y 1.5, Z 0.5) |

## Build and install

The compiled shaders are already in `addon/shaders/fxc`, so you only need to build if you change the `.hlsl` files. Building needs two things in `shaders/` that aren't included:

- `ShaderCompile.exe`: build the standalone compiler from [SCell555/ShaderCompile](https://github.com/SCell555/ShaderCompile).
- Valve's shader headers `common_fxc.h`, `common_hlsl_cpp_consts.h`, `common_pragmas.h`, `common_ps_fxc.h` and `common_vs_fxc.h`: copy them from `src/materialsystem/stdshaders` in [ValveSoftware/source-sdk-2013](https://github.com/ValveSoftware/source-sdk-2013).

```
shaders\build_shaders.bat      (compiles into addon\shaders\fxc)
python generate_common_assets.py   (only if you changed the common textures)
install_to_gmod.bat [path]     (garrysmod folder: the argument, the GMOD_PATH variable, a gitignored
                               install_config.local.bat containing set "GMOD_PATH=...", or Steam's default)
```

Then run `mat_reloadallmaterials` in-game. After changing a `.vcs` you may need to restart, because GMod caches shaders by name.

## Limitations

- **Flashlights and lamps don't cast shadows on ZZZ models.** The engine's flashlight shadow map can't be read from this shader, so a model inside a beam is lit even if something stands in between. Every beam also uses the same round shape (`effects/flashlight001`), whatever texture the lamp has.
- **Face shadow map G channel:** its purpose is unknown, so the face shader ignores it.
- **Outline width** is uniform. Source models carry no vertex colours, so ZZZ's per-vertex outline thickness (vertex colour R) is lost. Hard edges can split the hull.
- **Flashlight** is not supported (same as ExoPBR).
- **Every submaterial must use the shader.** If some submaterials of a model stay on VertexLitGeneric (for example the face and hair), the ZZZ submaterials render wrong. On Anby the whole body came out solid red with yellow lines, the LightMap's colours, while the VLG face and hair looked normal. This can't be fixed from the shader side (ExoPBR has the same limitation), so convert all of a model's materials. A VertexLitGeneric submaterial with `$bumpmap` + `$phong 1` is the only kind ExoPBR reports as safe to mix.
- **Native Linux** (ToGL) can't run SM3.0. The addon disables itself there; use Proton.

## License

MIT, see [LICENSE](LICENSE). This covers this project's own code and the textures it generates.

Building uses Valve's Source SDK 2013 headers, which aren't included (see Build and install). Character models, textures and game data you use with this shader belong to their owners and are not part of this repository.
