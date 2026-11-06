# AGENTS.md — guide for developers and AI agents

ZZZ-style NPR character shader for Garry's Mod on `screenspace_general_8tex`. See README.md for the user-facing overview, texture layout and cvars. This file covers the engine facts and contracts that are easy to break.

## 1. How a ZZZ model gets drawn

1. The `ZZZ` material proxy's `bind` installs `ZZZRenderOverride` on the entity (an existing override is kept in `ent.ZZZ_PrevRenderOverride` and called).
2. `ZZZRenderOverride`:
   1. **Populator draw:** an invisible VertexLitGeneric (`$bumpmap` + `$phong`) PopCan at the entity's light probe position, **one per entity** (`ent.ZZZ_Populator`, removed with the entity). A single shared populator, as ExoPBR uses, gets its lighting cached per frame, so every model got the lighting of whichever drew first (all models went dark while one in the shade was on screen). This makes the engine commit its lighting state: local lights (PS c20–c25, VS c27–c46), fog colour (PS c29) and HDR light scale (PS c30). screenspace_general never sets these itself; our shaders read the leftovers.
   2. `render.OverrideDepthEnable(true, true)` around the real draw, because screenspace_general disables depth writes.
   3. **Hair shadow** (`DrawHairShadow`, when the model has a receiving face and a casting hair submaterial), with depth writes off:
      1. **Mark:** the outline-style offset is smuggled through BOX_FRONT − BOX_BACK (positive and negative parts, because SetModelLighting may not take negatives) into `zzz_hairshadow_vs30`. The caster submaterials are drawn with `$disable_color_writes`, setting stencil bit 0x80 where they pass the depth test. Everything else gets `zzz_outline_skip`.
      2. **Shadow:** the normal populator runs again, then the face submaterials are drawn with a proxy-less copy (`zzz_faceshadow_ps30` = the face PS with `ZZZ_HAIR_SHADOW`, cel forced to 0, `$alpha_blend 1`) where the bit is set. Its constants are copied from the face material's last bind, with c17.w (render blend) replaced by the strength.
      3. **Clear:** the shifted casters again, writing 0 to the bit.
   4. **Outline pass:** suppress engine lighting, `render.SetModelLighting(BOX_FRONT, width, 0.5, 0.25)`, draw the populator again (commits that ambient cube to VS c21), cull front faces, `render.MaterialOverrideByIndex` every submaterial with its outline material (or `zzz_outline_skip`), draw, then restore.
   5. **Flashlights** (`DrawFlashlights`, `zzz_flashlight`): `render.RenderFlashlights` runs a callback per projected texture. Each one draws the **plain** VertexLitGeneric populator (`zzz_populator_flashlight`), then the model with every ZZZ submaterial swapped for its additive copy (`zzz_flashlight_ps30`, same textures plus the cookie `effects/flashlight001` in `$texture7`). Constants come from the material's settings in `matSettings`; c0 = (intensity, cel softness, cel threshold, `zzz_flashlight_strength`), c1 = (use normal map, ramp row or −1, alpha mode, max light), c2 = (cookie on, shadow strength). The shader includes `zzz_lighting_ps.h` with `ZZZ_FLASHLIGHT_PASS`, which leaves out everything that reads c11–c25. Attenuation follows Source: c + l/d + q/d², faded out over the last 40% of far Z. No flashlight shadows.
3. During the real draw, `bind` writes the material constants and the ambient cube (`render.ComputeLighting − render.ComputeDynamicLighting` in 6 directions, cached per entity per frame).

This mirrors ExoPBR (Workshop 3625705812; disassemble its `.vcs` files to compare, they aren't kept in this repo). When in doubt, check what ExoPBR does.

## 2. Engine facts (verified from ExoPBR's shipping shaders)

- **No `$softwareskin`.** GMod's screenspace_general with `$model 1` feeds hardware-skinning streams. The VS input layout must be exactly POSITION, BLENDWEIGHT, BLENDINDICES, NORMAL (UBYTE4-compressed normal + tangent), TEXCOORD0, POSITION1 / NORMAL1 (flex deltas). Compile with `#define COMPRESSED_VERTS 1` and use `DecompressVertex_NormalTangent`, `ApplyMorph` and `SkinPositionNormalAndTangentSpace(true, …)`.
  - *Earlier versions of this file said `$softwareskin 1` was mandatory and that normals were uncompressed floats. That came from a broken VS layout and was wrong; don't reintroduce it.*
- **No VS constants.** screenspace_general only sets PS constants. VS data has to be smuggled through the ambient cube (`render.SetModelLighting` under `SuppressEngineLighting`, committed by a VertexLitGeneric draw).
- **PS registers:**

  | reg | source |
  | :-- | :-- |
  | c0–c3 | `$c0_x` … `$c3_w` |
  | c4–c7 | texture pixel sizes, set by the engine; don't use |
  | c10 | `cEyePos` |
  | c11–c14 | `$viewprojmat` rows |
  | c15–c18 | `$invviewprojmat` rows |
  | c20–c25 | engine lights (populator); light 3 is packed in the `.w` components |
  | c29 | `g_LinearFogColor` (populator) |
  | c30 | `cLightScale` (populator) |

- **c11–c18 are always written.** GMod's screenspace_general_8tex writes `$viewprojmat` / `$invviewprojmat` into c11–c18 even when the material doesn't set them (identity by default). Verified by the flashlight probe: c13 read back as (0, 0, 1). Anything another shader leaves there is lost; c19–c31 and samplers above s7 survive.
- **Flashlights:** inside `render.RenderFlashlights`, a phong VertexLitGeneric leaves its flashlight data in c13–c18 (lost, see above). A plain VertexLitGeneric (no `$phong` / `$bumpmap`) leaves it in c22 (attenuation, far Z), c23 (position), c24–c27 (world-to-texture), c28 (colour), s7 (cookie), s8 (shadow depth), from SDK 2013 `vertexlitgeneric_dx9_helper.cpp`. A probe shader confirmed in game that c22 (attenuation read back as (0, 100, 0)), c28 and the c24–c27 matrix (the projection followed the aim) survive into a screenspace_general draw. The cookie (s7) and shadow map (s8) do **not** survive (black), so `zzz_flashlight_ps30` uses its own `$texture7` cookie and there are no flashlight shadows.
- **Depth:** never output DEPTH0. Use the Lua `OverrideDepthEnable` wrapper.
- **Don't rely on alpha 0 to hide geometry.** The SDK's screenspace_general enables an alpha test (alpha > 0), but in GMod an alpha-0 draw from `zzz_outline_skip` still covered the body in black (seen when the hair shadow passes started using it). To hide a submaterial, `zzz_outline_skip` uses `zzz_nodraw_vs30`, which places every vertex outside the clip volume. Colour-less passes also call `render.OverrideColorWriteEnable(true, false)`, not only `$disable_color_writes`. Cutouts (`alphamode 1`) discard with `clip()` in the pixel shader for the same reason. Blended transparency (`alphamode 2`) only works with `$alpha_blend 1` in the VMT; without it the alpha is ignored.
- **sRGB:** `$basetexture` is read as sRGB. `$texture1`–`3` need `$linearread_textureN 1`.
- **All submaterials of a model must use the ZZZ shader.** Mixing in plain VertexLitGeneric submaterials (for example a VLG face and hair) breaks the ZZZ parts. Observed on Anby: the body rendered solid red with yellow lines (the LightMap's colours) while the VLG face and hair were fine. This is an engine-state limitation shared with ExoPBR and can't be fixed in the shader. Don't spend time debugging that symptom; check the model's materials first.
- **Custom material vars don't persist.** `mat:SetFloat("$zzz_something", …)` on a var the shader doesn't define reads back as nothing (not even nil). Per-material settings live in the Lua `matSettings` table (filled by the proxy's `init`, read with `GetSettings(mat)`). Only real shader params (`$cN_x`, `$viewprojmat`, textures…) can be stored on the material.
- **`util.GetSunInfo().direction` points towards the sun.** Don't negate it. It has no colour field.

## 3. Constant contract

Shared by body and face (declared in `shaders/zzz_lighting_ps.h`, written by the proxy's `bind`):

| reg | xyz | w |
| :-- | :-- | :-- |
| c11 | ambient cube +X | fog enabled |
| c12, c13, c14 | ambient cube −X, +Y, −Y | manual key light direction x, y, z |
| c15 | ambient cube +Z | manual key light strength (0 = off; colour is fixed in the shader) |
| c16 | ambient cube −Z | rim width (fresnel power, `rimwidth`) |
| c17 | tint × colour modulation | render blend |
| c18 | emission tint (face: x = max light, 1e4 = off, since faces have no emission) | face only: nose line thresholds packed as round(side × 1000) + down (down clamped to < 1) |

`zzz_body_ps30`:

| reg | x | y | z | w |
| :-- | :-- | :-- | :-- | :-- |
| c0 | intensity | cel softness | cel threshold | rim strength |
| c1 | specular strength | matcap blend mode (0 replace, 1 add, 2 multiply) | max light (1e4 = off) | specular power (highlight size) |
| c2 | reserved | | | |
| c3 | alpha mode | emission scale | matcap strength | shadow strength |

`zzz_face_ps30` (samplers: s0 face `_D`, s1 face shadow map, s4 ramp; s6 is no longer used by either shader):

| reg | x | y | z | w |
| :-- | :-- | :-- | :-- | :-- |
| c0 | intensity | cel softness | cel threshold | rim strength |
| c1 | head forward x | y | z | face shadow strength |
| c2 | head right x | y | z | nose line strength |
| c3 | alpha mode | flip face map | ramp row | shadow strength |

`zzz_outline_ps30` also samples s1 (the body's LightMap) and s4 (the body's ramp): tint = ramp row 6 at the slot × 2. Its c3.x is a slot override (≥ 0, used for faces) or −1 to read the slot from LightMap.R.

`zzz_outline_ps30`: c0 = (darkness, flat-colour mix, fog enabled, alpha mode 0/1/2), c1.rgb = flat colour.
`zzz_outline_ps30` c2.rgb = light level at the entity (average ambient cube × intensity), set by `DrawOutline`.
`zzz_outline_vs30`: VS c21 (`cAmbientCubeX[0]`) = (width, 0.5, 0.25) and VS c22 (`cAmbientCubeX[1]`) = (max distance, FOV scale, min scale), where FOV scale = tan(fov/2) / tan(37.5°) from `render.GetViewSetup().fov`. With d = camera distance × FOV scale, push = width × 0.0009 × max(min(d, max distance), d × min scale), so the width stays constant on screen up close and is frozen in world units beyond the max distance. Without the signature, defaults are used (width 1, distance 100, min scale 0.5).

Constants are used verbatim. 0 is a meaningful value, so don't add "if 0 use default" fallbacks in HLSL. Defaults belong in Lua.

## 4. Shading model (body)

- All engine lights, the optional manual key light and the ambient cube's directionality are combined into one **weighted half-Lambert value**. It is multiplied by NormalMap.B occlusion and shifted by the threshold (`u = shade × occ − c0.z + 0.5`). That continuous value is the ramp U; the ramp's own bands do the cel shading (lit above 0.5, shallow 0.25–0.5, shadow below). A separate `smoothstep` cel value only masks specular and rim.
- **Slot / ramp row = `floor((1 − LightMap.R) × 4 + 0.5)`**. The order is reversed (R 1.0 = slot 1). This was verified on Anby: the hair JSON defines only slot 1 and the hair is 99% R = 1.0; the body defines 4 slots and R = 0 (0.6% of pixels) is the unused default slot 5.
- **Max light:** `CapLight` soft-caps the luminance of the total incident light (after `intensity`), keeping its colour: untouched below 75% of the cap, eased toward the cap above. The value is the material's `maxlight` key, else `zzz_max_light` (default 1; 0 = off); Lua sends 1e4 for "off" because constants are used verbatim. It's applied to the light, not the final colour, so shaded areas aren't affected. The outline's light level is capped the same way in Lua (`CapLightVector`).
- Diffuse = albedo × ramp × total incident light. Shadows are a ramp tint, not darkness from missing light, which is what keeps the anime look under any map lighting.
- **Ramp data rows** (numbers in alpha, because RGB is read as sRGB and alpha is always linear): row 5 = specular colour, A = `_ToonSpecular` × 4; row 6 = outline colour / 2, A = `_SpecularRange` / 4; row 7 A = 10 bins, `_MatCapColorBurst` / 4 for slots 1–5 then `_MatCapAlphaBurst` / 4. Ramps baked before this layout have alpha 255 and will read as huge values: rebake them.
- **Matcap:** masked by LightMap.G (`_UseMatCapMask`). Colour = matcap.rgb × colour burst, weight = saturate(matcap.a × alpha burst) × LightMap.G × strength, blended by `matcapmode`. *The meaning of `_MatCapBlendMode` values is a guess (0 replace, 1 add, 2 multiply); nothing public documents it.*
- **Specular:** stepped Blinn. **LightMap.B is the highlight amount, not a tightness**: 0 = no highlight (`smoothstep(0, 0.25, B)`). On Anby's hair B is 0 except for painted shine marks (H-shaped arcs), and MaterialMap.B is 255 everywhere, so B is what places the shine. An earlier version used B as the exponent, which gave 0 the widest highlight: the whole hair got a broad highlight and the shine marks a tiny one (visible as the shine looking dimmer than the rest of the hair). The size is a separate power, `zzz_spec_power` / `specpower` (c1.w), divided by `_SpecularRange`; `_ToonSpecular` is the smoothstep half-width. MaterialMap.B masks it, MaterialMap.G tints it by albedo.
- **Rim:** (1 − N·V)^`_FresnelWidth` on the lit side. Treating the width as a power is also a guess. Emission is unlit.

## 4b. Shading model (face)

- ZZZ faces are lit by a **face shadow map** (Anby's is `Female_Face_Lightmap.png`; the game shares it between characters of a body type, so it isn't in the per-character texture dump). Channels:
  - **R:** threshold gradient across the whole face, not mirrored (0 on one side, about 0.5 down the middle, 1 on the other).
  - **G:** unknown. It's 0.5 almost everywhere with one patch near an eye; unused.
  - **B:** nose highlight mask.
  - **A:** where the face shadow applies.
- `t = atan2(L·headRight, L·headForward) / π`, with L the weighted key direction from `GatherLights`. The face is lit where `R ≤ 1 + t` (t < 0) or `R ≥ t` (t ≥ 0). That gives fully lit from the front, half lit from the side and fully shadowed from behind. `t` is scaled toward 0 as the light approaches vertical.
- **Nose line (B):** the mark sits just left of the nose centre (U ≈ 0.486; U > 0.5 is the head's right, since R rises with U). It's shown when cos(horizontal view angle) < `noselineside` or, with the camera above, cos(vertical view angle) < `noselinedown`, and drawn in the slot's deep shadow tone. It's mirrored to the side away from the camera (`flipfacemap` swaps sides). The far-side rule is a guess; flip it if the line shows on the wrong side.
- The final cel value is a lerp between the normal-based cel and the face-map cel by `A × faceshadow`. It maps to ramp U = lerp(0.375, 1, cel), so a shadowed face sits in the shallow band and never reaches deep shadow, on ramp row `ramprow`.
- **Head vectors** come from the head bone matrix. The bone axes that point forward and right are auto-detected once per model, by picking the bone axis best aligned with `ent:GetForward()` / `ent:GetRight()`. Use the `zzz_face_recalibrate` command or the proxy keys `headforward` / `headright` if a rig gets it wrong, and `flipfacemap 1` if the face map's UVs are mirrored.
- Convert face maps with `tools/png_to_vtf.py <png> <vtf> --clamp`, and read them with `$linearread_texture1 1`.

## 5. Build, deploy, test

```
shaders\build_shaders.bat         needs shaders\ShaderCompile.exe and Valve's common_*.h headers (neither in the repo, both gitignored; standalone
                                  build from github.com/SCell555/ShaderCompile, headers from source-sdk-2013 src/materialsystem/stdshaders);
                                  compiles zzz_*_vs30/ps30 → addon\shaders\fxc (only tracked copy)
python generate_common_assets.py  regenerates addon\materials\models\zzz\common
install_to_gmod.bat [path]        copies addon\ into GarrysMod\garrysmod (path: argument, GMOD_PATH env var,
                                  gitignored install_config.local.bat, or Steam's default library)
```

- In game, run `mat_reloadallmaterials`. GMod caches shaders by name, so a changed `.vcs` may need a restart.
- **An invisible material with only its outline showing means GMod can't find the pixel shader.** Check that `garrysmod\shaders\fxc\` has the `.vcs` (re-run `install_to_gmod.bat` after every build), then restart.
- Nothing here can be tested without running GMod. Say so when reporting changes.

## 6. Open items

- Face shadow map: the G channel's meaning, and checking the head-axis auto-detection on more rigs.
- JSON data deliberately not used:
  - `_FresnelColor` (0, 0.2, 1.625): identical on every material, including the face, and it doesn't look like a colour. Probably packed parameters.
  - `_OutlineShadowColor`: 0 on every body slot and 0.491 on hair slot 1. Taken literally as a colour, it would turn body outlines black in shadow, and our outline already follows the light level.
  - `_ShapeFresnelScale` / `_ShapeFresnelOffset` (0.9 / 1.0 per slot), `_MatCapRefract*`, `_RimGlow*`: meaning unknown.
- Unused JSON data that could still be implemented:
  - the eye shader (`NapAvatarUIEye`, `Eye_E` colour map).
- The face uses vertex material IDs (`_UseVertexMaterialID 1`), which Source models can't carry.
- Smoothed outline normals (ZZZ stores them separately; Source loses them).
- **Flashlight flicker on jigglebones (open):** under a flashlight, jigglebone hair shows flickering patches without the flashlight's light. Likely cause: the flashlight pass is a second draw, the jigglebones get a slightly different pose in it, and those triangles fail the depth test against the main draw. A 0.5-unit depth bias toward the camera for that pass (body VS with a `ZZZ_DEPTH_BIAS` define) was tried and reverted before being tested; `r_jiggle_bones 0` would confirm the cause.
- Hair shadow (**unfinished, `zzz_hair_shadow` defaults to 0**). Never seen working in game yet: the passes ran and the model turned black (fixed via `zzz_nodraw_vs30`), but the shadow itself wasn't confirmed. Next steps: `zzz_hair_shadow 1`, then `zzz_hair_shadow_debug 1` / `2`, then tune `zzz_hair_shadow_offset`.
  - The game uses a dedicated `Anbi_HairShadow` mesh (plus a `FaceShadowPoint` node) that ported models lack, so the whole hair casts. Side locks level with the cheeks may cast more than in the game.
  - How the game applies `_XOffset` / `_YOffset` / `_ZOffset` (0.8 / 1.5 / 0.5) and `_XOffsetEnter` / `_YOffsetEnter` / `_XOffsetNew` is unknown. Here they're camera-space world offsets (side away from the light, down scaled by light height, toward the camera) × `zzz_hair_shadow_offset`.
  - The light direction comes from the ambient cube gradient plus the extra key light. Engine local lights aren't counted.

## 7. Git

Check `git status` and `git diff` before committing. Build intermediates (`shaders/shaders/`, `shaders/fxc/`) are gitignored. Use descriptive commit messages.
