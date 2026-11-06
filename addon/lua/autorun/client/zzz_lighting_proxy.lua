--[[-------------------------------------------------------------------------
    Zenless Zone Zero (ZZZ) NPR shader for Garry's Mod
    lua/autorun/client/zzz_lighting_proxy.lua

    screenspace_general_8tex knows nothing about model lighting, so this file
    (following ExoPBR's proven approach) supplies it:

      * Populator draw: before each ZZZ entity a tiny, invisible VertexLitGeneric
        ($bumpmap + $phong) model is drawn at the entity. That commits the engine's
        local lights (PS c20-c25, VS c27+), fog colour (c29) and HDR scale (c30),
        which our shader then reads.
      * Ambient cube: render.ComputeLighting in 6 directions, written into
        $viewprojmat / $invviewprojmat (PS c11-c18).
      * Depth: screenspace_general never writes depth, so the draw is wrapped in
        render.OverrideDepthEnable(true, true).
      * Outline: a second, inverted-hull pass with per-submaterial outline materials.
---------------------------------------------------------------------------]]

if SERVER then return end

-- Native Linux uses ToGL, which has no SM3.0 support
if system.IsLinux() then
    MsgC(Color(255, 120, 160), "[ZZZ Shader] Disabled: the native Linux build cannot run SM3.0 shaders (use Proton).\n")
    return
end

local render_OverrideDepthEnable     = render.OverrideDepthEnable
local render_ComputeLighting         = render.ComputeLighting
local render_ComputeDynamicLighting  = render.ComputeDynamicLighting
local render_GetBlend                = render.GetBlend
local render_SetBlend                = render.SetBlend
local render_GetColorModulation      = render.GetColorModulation
local render_GetFogMode              = render.GetFogMode
local render_MaterialOverride        = render.MaterialOverride
local render_MaterialOverrideByIndex = render.MaterialOverrideByIndex
local render_SuppressEngineLighting  = render.SuppressEngineLighting
local render_SetModelLighting        = render.SetModelLighting
local render_CullMode                = render.CullMode

local ENT = FindMetaTable("Entity")
local DrawModel = ENT.DrawModel

local COMMON = "models/zzz/common/"

---------------------------------------------------------------------------
-- ConVars (global multipliers on top of the per-material values)
---------------------------------------------------------------------------
local function CV(name, default, help)
    return CreateClientConVar(name, tostring(default), true, false, help)
end

local cv_intensity     = CV("zzz_intensity", 1.0, "Overall light multiplier")
local cv_ambient       = CV("zzz_ambient_scale", 1.0, "Ambient cube multiplier")
local cv_softness      = CV("zzz_cel_softness", 0.03, "Cel shadow edge softness (0.005 crisp .. 0.2 soft)")
local cv_threshold     = CV("zzz_cel_threshold", 0.5, "Cel shadow threshold on the half-Lambert value")
local cv_shadow        = CV("zzz_shadow_strength", 1.0, "How strongly the ramp's shadow colour applies (0 = no shadows)")
local cv_rim           = CV("zzz_rim_strength", 1.0, "Rim light multiplier")
local cv_spec          = CV("zzz_spec_strength", 1.0, "Specular multiplier")
local cv_spec_power    = CV("zzz_spec_power", 16, "Specular highlight size: higher = smaller, tighter highlights (a material's specpower key overrides this)")
local cv_max_light     = CV("zzz_max_light", 1, "Soft cap on how bright the light on a model can get (1 = never brighter than its texture, 0 = off). A material's own maxlight key overrides this")
local cv_light_mode    = CV("zzz_light_override", 0, "Extra key light: 0 off, 1 manual yaw/pitch, 2 map sun direction")
local cv_light_yaw     = CV("zzz_light_yaw", 45, "Manual key light yaw (0-360)")
local cv_light_pitch   = CV("zzz_light_pitch", 45, "Manual key light elevation (0-90)")
local cv_light_power   = CV("zzz_light_strength", 0.8, "Extra key light strength")
local cv_outline       = CV("zzz_outline", 1, "Draw inverted-hull outlines (0/1)")
local cv_outline_width = CV("zzz_outline_width", 1.0, "Outline thickness multiplier")
local cv_outline_dist  = CV("zzz_outline_max_distance", 100, "Camera distance past which outlines stop growing (they shrink with the model beyond it)")
local cv_outline_min   = CV("zzz_outline_min_scale", 0.5, "Far away, outlines never get thinner on screen than this fraction of their close-up width (0-1)")
local cv_outline_dark  = CV("zzz_outline_darkness", 0.35, "Outline colour = diffuse * this")
local cv_hair_shadow   = CV("zzz_hair_shadow", 0, "Hair casts a shadow onto the face (0/1). Experimental, not yet verified in game")
local cv_hair_strength = CV("zzz_hair_shadow_strength", 1.0, "Hair shadow opacity on the face (0-1)")
local cv_hair_debug    = CV("zzz_hair_shadow_debug", 0, "Hair shadow debug: 1 = show the shifted hair in magenta, 2 = shadow the whole face (no stencil)")
local cv_hair_offset   = CV("zzz_hair_shadow_offset", 0.4, "Hair shadow shift in world units per game offset unit (game: X 0.8, Y 1.5, Z 0.5)")

---------------------------------------------------------------------------
-- Populator: commits engine lighting state for the next screenspace_general draw
---------------------------------------------------------------------------
local populatorMaterial = CreateMaterial("zzz_populator", "VertexLitGeneric", {
    ["$basetexture"] = "color/white",
    ["$bumpmap"]     = COMMON .. "neutral_normal",
    ["$phong"]       = 1,
    ["$model"]       = 1,
})

-- One populator per ZZZ entity. The engine caches a model's lighting per frame, so a single shared
-- populator moved from entity to entity hands every entity the lighting of whichever drew first
-- (seen as all models going dark while one in the shade was on screen). ExoPBR shares one.
local function RemovePopulator(ent)
    if IsValid(ent.ZZZ_Populator) then ent.ZZZ_Populator:Remove() end
    ent.ZZZ_Populator = nil
end

local function GetPopulator(ent)
    local p = ent.ZZZ_Populator
    if IsValid(p) then return p end
    p = ClientsideModel("models/props_junk/PopCan01a.mdl", RENDERGROUP_OPAQUE)
    if not IsValid(p) then return end
    p:SetNoDraw(true)
    p:SetModelScale(1e-9)
    ent.ZZZ_Populator = p
    ent:CallOnRemove("ZZZ_RemovePopulator", RemovePopulator)
    return p
end

-- Plain VertexLitGeneric (no $phong / $bumpmap) for flashlight passes: its flashlight data lands in
-- PS c22-c28 and s7/s8, which screenspace_general_8tex doesn't overwrite. The phong populator's
-- flashlight data lands in c13-c18, which 8tex always overwrites with $viewprojmat/$invviewprojmat.
local populatorFlashlightMaterial = CreateMaterial("zzz_populator_flashlight", "VertexLitGeneric", {
    ["$basetexture"] = "color/white",
    ["$model"]       = 1,
})

local function DrawPopulator(ent, pos, mat)
    local p = GetPopulator(ent)
    if not IsValid(p) then return end
    p:SetPos(pos)
    local blend = render_GetBlend()
    render_SetBlend(0)
    render_MaterialOverride(mat or populatorMaterial)
    DrawModel(p)
    render_MaterialOverride()
    render_SetBlend(blend)
end

local PROBE_OFFSET = Vector(0, 0, 8)
local function LightProbePos(ent)
    local origin = ent:GetRenderOrigin()
    if origin then return origin + PROBE_OFFSET end
    return ent:WorldSpaceCenter()
end

---------------------------------------------------------------------------
-- Ambient cube, cached per entity per frame (bind runs once per submaterial)
---------------------------------------------------------------------------
local DIRS = {
    Vector(1, 0, 0), Vector(-1, 0, 0),
    Vector(0, 1, 0), Vector(0, -1, 0),
    Vector(0, 0, 1), Vector(0, 0, -1),
}

local function GetAmbientCube(ent)
    local frame = FrameNumber()
    local cache = ent.ZZZ_Ambient
    if cache and cache.frame == frame then return cache end
    cache = cache or {}
    local pos = LightProbePos(ent)
    local scale = cv_ambient:GetFloat()
    for i = 1, 6 do
        -- Dynamic lights reach the shader through the populator's light list; don't count them twice
        cache[i] = (render_ComputeLighting(pos, DIRS[i]) - render_ComputeDynamicLighting(pos, DIRS[i])) * scale
    end
    cache.frame = frame
    ent.ZZZ_Ambient = cache
    return cache
end

---------------------------------------------------------------------------
-- Extra key light (packed into the ambient matrices' spare .w slots; colour is fixed in the shader)
---------------------------------------------------------------------------
local function GetKeyLight()
    local mode = cv_light_mode:GetInt()
    if mode == 1 then
        -- Angle pitch is negative when looking up; we want a vector pointing up towards the light
        return Angle(-cv_light_pitch:GetFloat(), cv_light_yaw:GetFloat(), 0):Forward(), cv_light_power:GetFloat()
    elseif mode == 2 then
        local sun = util.GetSunInfo()
        -- direction already points towards the sun: do not negate
        if sun and sun.direction then
            return sun.direction, cv_light_power:GetFloat() * (1 - (sun.obstruction or 0))
        end
    end
    return vector_up, 0
end

---------------------------------------------------------------------------
-- Head direction for the face shader
--
-- Rigs differ in which bone axis points out of the face, so the axes are calibrated once per
-- model: the head bone axis best aligned with the entity's forward/right wins. Proxy keys
-- "headforward"/"headright" ("x", "-x", "y", "-y", "z", "-z") override this.
---------------------------------------------------------------------------
local AXIS_GET = {
    x = function(m) return m:GetForward() end,
    y = function(m) return -m:GetRight() end,   -- matrix +Y (left)
    z = function(m) return m:GetUp() end,
}

local function ParseAxis(spec)
    if not spec then return nil end
    spec = string.lower(string.Trim(tostring(spec)))
    local sign, axis = 1, spec
    if string.StartsWith(spec, "-") then sign, axis = -1, string.sub(spec, 2) end
    if string.StartsWith(axis, "+") then axis = string.sub(axis, 2) end
    if not AXIS_GET[axis] then return nil end
    return { axis = axis, sign = sign }
end

local headCalibration = {}
concommand.Add("zzz_face_recalibrate", function() headCalibration = {} end,
    nil, "Re-detect head bone axes for ZZZ face materials")

local function BestAxis(m, target, exclude)
    local best, bestDot
    for axis, get in pairs(AXIS_GET) do
        if axis ~= exclude then
            local d = get(m):Dot(target)
            if not bestDot or math.abs(d) > math.abs(bestDot) then best, bestDot = axis, d end
        end
    end
    return { axis = best, sign = bestDot < 0 and -1 or 1 }
end

local function GetHeadVectors(ent, boneName, fwdOverride, rightOverride)
    local bone = ent:LookupBone(boneName)
    local m = bone and ent:GetBoneMatrix(bone)
    if not m then return ent:GetForward(), ent:GetRight() end

    local key = ent:GetModel() .. "|" .. boneName
    local cal = headCalibration[key]
    if not cal then
        local fwd = fwdOverride or BestAxis(m, ent:GetForward())
        local right = rightOverride or BestAxis(m, ent:GetRight(), fwd.axis)
        cal = { fwd = fwd, right = right }
        headCalibration[key] = cal
    end
    return AXIS_GET[cal.fwd.axis](m) * cal.fwd.sign, AXIS_GET[cal.right.axis](m) * cal.right.sign
end

---------------------------------------------------------------------------
-- Per-material settings from the proxy block, keyed by material name.
-- (Custom "$zzz_*" vars set with IMaterial:SetFloat don't persist in GMod, so they live here.)
---------------------------------------------------------------------------
local matSettings = {}

local function GetSettings(mat)
    local name = mat:GetName()
    local st = matSettings[name]
    if st then return st end
    -- Proxy init hasn't run (or the material has no ZZZ proxy): defaults
    local isFace = string.StartsWith(mat:GetString("$pixshader") or "", "zzz_face")
    local isHair = string.find(string.lower(name), "hair", 1, true) ~= nil
    return { outline = 1, alphaMode = 0, rampRow = 0, hairShadow = (isFace or isHair) and 1 or 0 }
end

-- Value sent to the shaders: the material's maxlight key if it has one, else the global cvar.
-- 0 means off, sent as a huge number because the shaders use constants verbatim.
local CAP_OFF = 1e4
local function EffectiveMaxLight(materialValue)
    local cap = materialValue or cv_max_light:GetFloat()
    return cap > 0 and cap or CAP_OFF
end

-- Same soft cap as CapLight in zzz_lighting_ps.h (used for the outline's light level)
local function CapLightVector(light, cap)
    local lum = light.x * 0.2126 + light.y * 0.7152 + light.z * 0.0722
    local knee = cap * 0.75
    if lum <= knee then return light end
    local room = cap - knee
    local capped = knee + room * (1 - math.exp(-(lum - knee) / room))
    return light * (capped / lum)
end

---------------------------------------------------------------------------
-- Outline materials (one per ZZZ body/face material, sharing its diffuse)
---------------------------------------------------------------------------
-- The outline shares the body's diffuse, LightMap ($texture1, picks the slot) and ramp ($texture4,
-- row 6 = per-slot _OutlineColor). rowOverride >= 0 forces a slot (faces have no LightMap).
local function NewOutlineMaterial(name, baseTexture, lightMap, ramp, alphaMode, rowOverride, vertexShader)
    local mat = CreateMaterial(name, "screenspace_general_8tex", {
        ["$pixshader"]           = "zzz_outline_ps30",
        ["$vertexshader"]        = vertexShader or "zzz_outline_vs30",
        ["$basetexture"]         = baseTexture or "color/white",
        ["$texture1"]            = lightMap or (COMMON .. "neutral_lightmap"),
        ["$texture4"]            = ramp or (COMMON .. "toon_ramp"),
        ["$linearread_texture1"] = 1,
        ["$model"]               = 1,
        ["$cull"]                = 1,
        ["$depthtest"]           = 1,
        ["$vertexnormal"]        = 1,
    })
    mat:SetFloat("$c0_w", alphaMode)
    mat:SetFloat("$c3_x", rowOverride or -1)
    return mat
end

-- Hides a submaterial in the outline / hair shadow passes. Its vertex shader clips every vertex;
-- alpha 0 alone is not discarded reliably (seen as black shells over the body).
local skipOutline = NewOutlineMaterial("zzz_outline_skip", "color/white", nil, nil, 2, 0, "zzz_nodraw_vs30")

local function TextureName(mat, key)
    local tex = mat:GetTexture(key)
    if tex and not tex:IsErrorTexture() then return tex:GetName() end
end
local outlineCache = {}

local function GetOutlineMaterial(bodyMat)
    local name = bodyMat:GetName()
    local cached = outlineCache[name]
    if cached ~= nil then return cached end

    local mat = false
    local ps = bodyMat:GetString("$pixshader") or ""
    if (string.StartsWith(ps, "zzz_body") or string.StartsWith(ps, "zzz_face")) and GetSettings(bodyMat).outline ~= 0 then
        local isFace = string.StartsWith(ps, "zzz_face")
        local alphaMode = GetSettings(bodyMat).alphaMode == 1 and 1 or 0
        mat = NewOutlineMaterial("zzz_outline_" .. util.CRC(name),
            TextureName(bodyMat, "$basetexture"),
            not isFace and TextureName(bodyMat, "$texture1") or nil,
            TextureName(bodyMat, "$texture4"),
            alphaMode,
            isFace and GetSettings(bodyMat).rampRow or -1)
    end
    outlineCache[name] = mat
    return mat
end

-- Submaterial index -> outline material, refreshed once a second per entity
local function GetOutlineSet(ent)
    local now = RealTime()
    local set = ent.ZZZ_OutlineSet
    if set and set.model == ent:GetModel() and now < set.expires then return set end

    set = { model = ent:GetModel(), expires = now + 1, mats = {}, any = false, faces = {}, casters = {}, caps = {}, src = {} }
    for i, path in ipairs(ent:GetMaterials()) do
        local sub = ent:GetSubMaterial(i - 1)
        local src = Material(sub ~= "" and sub or path)
        local outline = GetOutlineMaterial(src)
        set.mats[i - 1] = outline or skipOutline
        set.caps[i - 1] = GetSettings(src).maxLight
        set.src[i - 1] = src
        if outline then set.any = true end

        -- Hair shadow: faces receive (hairshadow = strength), materials with hairshadow 1 cast
        local ps = src:GetString("$pixshader") or ""
        local hs = GetSettings(src).hairShadow
        if hs > 0 then
            if string.StartsWith(ps, "zzz_face") then
                set.faces[i - 1] = src
            elseif string.StartsWith(ps, "zzz_body") then
                set.casters[i - 1] = true
            end
        end
    end
    set.hairShadow = next(set.faces) ~= nil and next(set.casters) ~= nil
    ent.ZZZ_OutlineSet = set
    return set
end

local function DrawOutline(ent, flags)
    local set = GetOutlineSet(ent)
    if not set.any then return end

    local darkness = cv_outline_dark:GetFloat()
    local fog = render_GetFogMode() ~= MATERIAL_FOG_NONE and 1 or 0

    -- Light the outline like the body: average of the entity's ambient cube (same data the body
    -- shader uses for its incident light) times the global intensity
    local a = GetAmbientCube(ent)
    local light = (a[1] + a[2] + a[3] + a[4] + a[5] + a[6]) * (cv_intensity:GetFloat() / 6)

    for idx, mat in pairs(set.mats) do
        if mat ~= skipOutline then
            local capped = CapLightVector(light, EffectiveMaxLight(set.caps[idx]))
            mat:SetFloat("$c0_x", darkness)
            mat:SetFloat("$c0_z", fog)
            mat:SetFloat("$c2_x", capped.x)
            mat:SetFloat("$c2_y", capped.y)
            mat:SetFloat("$c2_z", capped.z)
        end
    end

    -- Width goes to the vertex shader through the ambient cube (+X), with a 0.5/0.25 signature
    render_SuppressEngineLighting(true)
    render_SetModelLighting(BOX_FRONT, cv_outline_width:GetFloat() * (ent.ZZZ_OutlineWidth or 1), 0.5, 0.25)
    -- FOV scale relative to GMod's default 75: zooming in (camera SWEP, scopes) counts as getting closer
    local view = render.GetViewSetup()
    local fov = math.Clamp(view and view.fov or 75, 1, 179)
    local fovScale = math.tan(math.rad(fov * 0.5)) / math.tan(math.rad(75 * 0.5))
    render_SetModelLighting(BOX_BACK, math.max(cv_outline_dist:GetFloat(), 1), fovScale,
        math.Clamp(cv_outline_min:GetFloat(), 0, 1))
    DrawPopulator(ent, LightProbePos(ent)) -- commits the custom ambient cube to the VS constants
    render_CullMode(MATERIAL_CULLMODE_CW)

    for idx, mat in pairs(set.mats) do render_MaterialOverrideByIndex(idx, mat) end
    DrawModel(ent, flags)
    for idx in pairs(set.mats) do render_MaterialOverrideByIndex(idx, nil) end

    render_CullMode(MATERIAL_CULLMODE_CCW)
    render_SuppressEngineLighting(false)
end

---------------------------------------------------------------------------
-- Hair shadow on the face (stand-in for ZZZ's NapStencilShadowCaster)
--
-- The game draws a dedicated HairShadow mesh; ported models only have the hair, so the hair
-- submaterials cast. After the main draw:
--   1. mark:   hair shifted by the light/camera offset, colour writes off, depth test on (so only
--              hair in front of the face counts, not the back hair) -> stencil bit 0x80
--   2. shadow: the face redrawn with zzz_faceshadow_ps30 where the bit is set, alpha = strength
--   3. clear:  the shifted hair again, zeroing the bit
---------------------------------------------------------------------------
local STENCIL_BIT = 0x80

local hairCaster = CreateMaterial("zzz_hairshadow_caster", "screenspace_general_8tex", {
    ["$pixshader"]            = "zzz_outline_ps30",
    ["$vertexshader"]         = "zzz_hairshadow_vs30",
    ["$basetexture"]          = "color/white",
    ["$texture1"]             = COMMON .. "neutral_lightmap",
    ["$texture4"]             = COMMON .. "toon_ramp",
    ["$linearread_texture1"]  = 1,
    ["$disable_color_writes"] = 1,
    ["$model"]                = 1,
    ["$cull"]                 = 1,
    ["$depthtest"]            = 1,
    ["$vertexnormal"]         = 1,
})
hairCaster:SetFloat("$c0_w", 0)   -- opaque: never alpha-tested away
hairCaster:SetFloat("$c2_x", 1)
hairCaster:SetFloat("$c2_y", 1)
hairCaster:SetFloat("$c2_z", 1)

-- Debug: the same caster, visible in flat magenta
local hairCasterDebug = CreateMaterial("zzz_hairshadow_caster_debug", "screenspace_general_8tex", {
    ["$pixshader"]            = "zzz_outline_ps30",
    ["$vertexshader"]         = "zzz_hairshadow_vs30",
    ["$basetexture"]          = "color/white",
    ["$texture1"]             = COMMON .. "neutral_lightmap",
    ["$texture4"]             = COMMON .. "toon_ramp",
    ["$linearread_texture1"]  = 1,
    ["$model"]                = 1,
    ["$cull"]                 = 1,
    ["$depthtest"]            = 1,
    ["$vertexnormal"]         = 1,
})
hairCasterDebug:SetFloat("$c0_y", 1)   -- flat colour
hairCasterDebug:SetFloat("$c0_w", 0)
hairCasterDebug:SetFloat("$c1_x", 1)
hairCasterDebug:SetFloat("$c1_z", 1)
hairCasterDebug:SetFloat("$c2_x", 1)
hairCasterDebug:SetFloat("$c2_y", 1)
hairCasterDebug:SetFloat("$c2_z", 1)
hairCasterDebug:SetFloat("$c3_x", 0)

local SHADOW_VMATRIX = Matrix()
local FACE_CONSTANTS = {}
for _, r in ipairs({ "c0", "c1", "c2", "c3" }) do
    for _, c in ipairs({ "x", "y", "z", "w" }) do FACE_CONSTANTS[#FACE_CONSTANTS + 1] = "$" .. r .. "_" .. c end
end

-- Proxy-less copy of a face material with the shadow pixel shader; constants are copied per draw
local faceShadowCache = {}
local function GetFaceShadowMaterial(faceMat)
    local name = faceMat:GetName()
    local mat = faceShadowCache[name]
    if mat then return mat end
    mat = CreateMaterial("zzz_faceshadow_" .. util.CRC(name), "screenspace_general_8tex", {
        ["$pixshader"]           = "zzz_faceshadow_ps30",
        ["$vertexshader"]        = "zzz_body_vs30",
        ["$basetexture"]         = TextureName(faceMat, "$basetexture") or "color/white",
        ["$texture1"]            = TextureName(faceMat, "$texture1") or (COMMON .. "black"),
        ["$texture4"]            = TextureName(faceMat, "$texture4") or (COMMON .. "toon_ramp"),
        ["$linearread_texture1"] = 1,
        ["$alpha_blend"]         = 1,
        ["$model"]               = 1,
        ["$cull"]                = 1,
        ["$depthtest"]           = 1,
        ["$vertexnormal"]        = 1,
    })
    faceShadowCache[name] = mat
    return mat
end

local function Luma(v) return v.x * 0.2126 + v.y * 0.7152 + v.z * 0.0722 end

-- Dominant light direction at the entity: ambient cube gradient + the extra key light
local function GetShadowLightDir(ent)
    local a = GetAmbientCube(ent)
    local dir = Vector(Luma(a[1]) - Luma(a[2]), Luma(a[3]) - Luma(a[4]), Luma(a[5]) - Luma(a[6]))
    local keyDir, keyPower = GetKeyLight()
    dir = dir + keyDir * keyPower
    if dir:LengthSqr() < 1e-8 then return vector_up end
    dir:Normalize()
    return dir
end

-- Game offsets from MAT_HairShadow_UI (_XOffset / _YOffset / _ZOffset)
local HAIR_X, HAIR_Y, HAIR_Z = 0.8, 1.5, 0.5

local function SetCasterOffset(ent)
    local view = render.GetViewSetup()
    local ang = view and view.angles or EyeAngles()
    local camFwd, camRight, camUp = ang:Forward(), ang:Right(), ang:Up()
    local L = GetShadowLightDir(ent)
    local k = cv_hair_offset:GetFloat()

    -- Sideways away from the light, down (less when the light is low), toward the camera
    local side = -L:Dot(camRight) * HAIR_X
    local down = HAIR_Y * math.Clamp(0.5 + 0.5 * L:Dot(camUp), 0, 1)
    local o = (camRight * side - camUp * down - camFwd * HAIR_Z) * k
    ent.ZZZ_HairDebug = { light = L, offset = o }

    render_SuppressEngineLighting(true)
    render_SetModelLighting(BOX_FRONT, math.max(o.x, 0), math.max(o.y, 0), math.max(o.z, 0))
    render_SetModelLighting(BOX_BACK, math.max(-o.x, 0), math.max(-o.y, 0), math.max(-o.z, 0))
    DrawPopulator(ent, LightProbePos(ent))
    render_SuppressEngineLighting(false)
end

local function DrawCasters(ent, flags, set, caster)
    for idx in pairs(set.mats) do
        render_MaterialOverrideByIndex(idx, set.casters[idx] and (caster or hairCaster) or skipOutline)
    end
    -- The real caster must only touch the stencil ($disable_color_writes as well as this)
    if not caster then
        render.OverrideColorWriteEnable(true, false)
        render.OverrideAlphaWriteEnable(true, false)
    end
    DrawModel(ent, flags)
    if not caster then
        render.OverrideColorWriteEnable(false, false)
        render.OverrideAlphaWriteEnable(false, false)
    end
    for idx in pairs(set.mats) do render_MaterialOverrideByIndex(idx, nil) end
end

local function DrawHairShadowPasses(ent, flags)
    local set = GetOutlineSet(ent)
    if not set.hairShadow then return end
    local strength = math.Clamp(cv_hair_strength:GetFloat(), 0, 1)
    if strength <= 0 then return end
    local debug = cv_hair_debug:GetInt()

    render.SetStencilEnable(true)
    render.SetStencilWriteMask(STENCIL_BIT)
    render.SetStencilTestMask(STENCIL_BIT)
    render.SetStencilFailOperation(STENCIL_KEEP)
    render.SetStencilZFailOperation(STENCIL_KEEP)
    render_OverrideDepthEnable(true, false)

    -- 1. mark
    SetCasterOffset(ent)
    render.SetStencilReferenceValue(STENCIL_BIT)
    render.SetStencilCompareFunction(STENCIL_ALWAYS)
    render.SetStencilPassOperation(STENCIL_REPLACE)
    DrawCasters(ent, flags, set)

    -- 2. shadowed face, with normal lighting committed again
    DrawPopulator(ent, LightProbePos(ent))
    render.SetStencilCompareFunction(debug == 2 and STENCIL_ALWAYS or STENCIL_EQUAL)
    render.SetStencilPassOperation(STENCIL_KEEP)
    for idx in pairs(set.mats) do
        local face = set.faces[idx]
        local st = face and matSettings[face:GetName()]
        local b = st and st.bound
        if b and b.m1 and b.m2 then
            local sm = GetFaceShadowMaterial(face)
            for _, key in ipairs(FACE_CONSTANTS) do sm:SetFloat(key, b.c[key] or 0) end
            SHADOW_VMATRIX:SetUnpacked(unpack(b.m1))
            sm:SetMatrix("$viewprojmat", SHADOW_VMATRIX)
            -- c17.w (render blend, element 12) carries the strength, times the face's own hairshadow value
            local m2 = table.Copy(b.m2)
            m2[12] = m2[12] * strength * st.hairShadow
            SHADOW_VMATRIX:SetUnpacked(unpack(m2))
            sm:SetMatrix("$invviewprojmat", SHADOW_VMATRIX)
            render_MaterialOverrideByIndex(idx, sm)
        else
            render_MaterialOverrideByIndex(idx, skipOutline)
        end
    end
    DrawModel(ent, flags)
    for idx in pairs(set.mats) do render_MaterialOverrideByIndex(idx, nil) end

    -- 3. clear our bit again
    SetCasterOffset(ent)
    render.SetStencilReferenceValue(0)
    render.SetStencilCompareFunction(STENCIL_ALWAYS)
    render.SetStencilPassOperation(STENCIL_REPLACE)
    DrawCasters(ent, flags, set)

    render.SetStencilEnable(false)

    -- Debug 1: where the shifted hair lands and passes the depth test (= what marks the stencil)
    if debug == 1 then
        SetCasterOffset(ent)
        DrawCasters(ent, flags, set, hairCasterDebug)
    end

    render_OverrideDepthEnable(true, true)
    DrawPopulator(ent, LightProbePos(ent))
end

-- Any error mid-way would leave stencil, depth and material overrides stuck for the rest of the
-- frame (and the model drawn with the wrong materials), so always restore
local hairShadowErrorShown = false
local function DrawHairShadow(ent, flags)
    local ok, err = pcall(DrawHairShadowPasses, ent, flags)
    if ok then return end
    render.SetStencilEnable(false)
    render_SuppressEngineLighting(false)
    render.OverrideColorWriteEnable(false, false)
    render.OverrideAlphaWriteEnable(false, false)
    for i = 0, #ent:GetMaterials() - 1 do render_MaterialOverrideByIndex(i, nil) end
    render_OverrideDepthEnable(true, true)
    DrawPopulator(ent, LightProbePos(ent))
    if not hairShadowErrorShown then
        hairShadowErrorShown = true
        ErrorNoHalt("[ZZZ Shader] hair shadow failed (disabled for this frame): " .. tostring(err) .. "\n")
    end
end

-- Prints what the hair shadow sees on the entity you're looking at (or yourself in third person)
concommand.Add("zzz_hair_shadow_info", function()
    local ply = LocalPlayer()
    local ent = ply:GetEyeTrace().Entity
    if not IsValid(ent) then ent = ply end
    print("[ZZZ hair shadow] " .. tostring(ent) .. "  " .. ent:GetModel())
    print("  drawn by ZZZ: " .. tostring(ent.ZZZ_Ambient ~= nil and ent.RenderOverride ~= nil))
    ent.ZZZ_OutlineSet = nil
    local set = GetOutlineSet(ent)
    for i, path in ipairs(ent:GetMaterials()) do
        local sub = ent:GetSubMaterial(i - 1)
        local m = Material(sub ~= "" and sub or path)
        local role = set.faces[i - 1] and "RECEIVES" or (set.casters[i - 1] and "CASTS" or "-")
        print(string.format("  [%d] %-40s ps=%-16s hairshadow=%s  %s", i - 1, m:GetName(),
            m:GetString("$pixshader") or "?", tostring(GetSettings(m).hairShadow), role))
        if set.faces[i - 1] then
            local st = matSettings[m:GetName()]
            local b = st and st.bound
            if b and b.m2 then
                print(string.format("      recorded: intensity %s  softness %s  blend %s",
                    tostring(b.c["$c0_x"]), tostring(b.c["$c0_y"]), tostring(b.m2[12])))
            else
                print("      no recorded constants (proxy bind hasn't run for this face)")
            end
        end
    end
    print("  active: " .. tostring(set.hairShadow) .. "   zzz_hair_shadow " .. cv_hair_shadow:GetInt() ..
        "   strength " .. cv_hair_strength:GetFloat() .. "   offset scale " .. cv_hair_offset:GetFloat())
    local d = ent.ZZZ_HairDebug
    if d then
        print("  light dir " .. tostring(d.light) .. "   offset " .. tostring(d.offset) ..
            " (length " .. math.Round(d.offset:Length(), 3) .. ")")
    else
        print("  no offset computed yet (the passes haven't run for this entity)")
    end
end, nil, "Print hair shadow diagnostics for the entity you're looking at")

---------------------------------------------------------------------------
-- Flashlights / projected textures (additive pass, zzz_flashlight_ps30)
--
-- render.RenderFlashlights calls us once per projected texture with the engine in flashlight mode.
-- A PLAIN VertexLitGeneric populator drawn there leaves the flashlight's attenuation, position,
-- matrix and colour in PS c22-c28, which screenspace_general_8tex never writes (a phong populator
-- leaves them in c13-c18, which 8tex always overwrites). The engine's cookie and shadow map don't
-- survive, so the cookie is our own $texture7 and there are no flashlight shadows.
-- Verified in game with a probe shader (removed); see AGENTS.md.
---------------------------------------------------------------------------
local cv_flashlight    = CV("zzz_flashlight", 1, "Flashlights and projected textures light ZZZ models (0/1)")
local cv_fl_strength   = CV("zzz_flashlight_strength", 1.0, "Flashlight / projected texture brightness on ZZZ models")
local cv_fl_cookie     = CV("zzz_flashlight_cookie", 1, "1 = beam shaped by the standard flashlight texture, 0 = plain soft circle")

local FLASHLIGHT_COOKIE = "effects/flashlight001"

-- Additive flashlight copy of each ZZZ material (same textures), cached by material name
local flashlightCache = {}
local function GetFlashlightMaterial(src)
    local name = src:GetName()
    local cached = flashlightCache[name]
    if cached ~= nil then return cached end

    local ps = src:GetString("$pixshader") or ""
    local isFace = string.StartsWith(ps, "zzz_face")
    if not isFace and not string.StartsWith(ps, "zzz_body") then
        flashlightCache[name] = false
        return false
    end
    local kv = {
        ["$pixshader"]           = "zzz_flashlight_ps30",
        ["$vertexshader"]        = "zzz_body_vs30",
        ["$basetexture"]         = TextureName(src, "$basetexture") or "color/white",
        ["$texture4"]            = TextureName(src, "$texture4") or (COMMON .. "toon_ramp"),
        ["$texture7"]            = FLASHLIGHT_COOKIE,
        ["$linearread_texture1"] = 1,
        ["$linearread_texture2"] = 1,
        ["$linearread_texture3"] = 1,
        ["$model"]               = 1,
        ["$cull"]                = 1,
        ["$depthtest"]           = 1,
        ["$vertexnormal"]        = 1,
        ["$additive"]            = 1,
    }
    if not isFace then
        kv["$texture1"] = TextureName(src, "$texture1") or (COMMON .. "neutral_lightmap")
        kv["$texture2"] = TextureName(src, "$texture2") or (COMMON .. "neutral_normal")
        kv["$texture3"] = TextureName(src, "$texture3") or (COMMON .. "neutral_materialmap")
    end
    cached = { mat = CreateMaterial("zzz_flashlight_" .. util.CRC(name), "screenspace_general_8tex", kv), isFace = isFace }
    flashlightCache[name] = cached
    return cached
end

local function SetFlashlightConstants(m, st, isFace)
    m:SetFloat("$c0_x", cv_intensity:GetFloat() * (st.intensity or 1))
    m:SetFloat("$c0_y", cv_softness:GetFloat())
    m:SetFloat("$c0_z", cv_threshold:GetFloat())
    m:SetFloat("$c0_w", cv_fl_strength:GetFloat())
    m:SetFloat("$c1_x", isFace and 0 or 1)                      -- normal map
    m:SetFloat("$c1_y", isFace and (st.rampRow or 0) or -1)     -- ramp row (faces have no LightMap)
    m:SetFloat("$c1_z", st.alphaMode or 0)
    m:SetFloat("$c1_w", EffectiveMaxLight(st.maxLight))
    m:SetFloat("$c2_x", cv_fl_cookie:GetBool() and 1 or 0)
    m:SetFloat("$c2_y", cv_shadow:GetFloat() * (st.shadow or 1))
end

local function DrawFlashlightPasses(ent, flags)
    local set = GetOutlineSet(ent)
    local overrides, any = {}, false
    for idx, src in pairs(set.src) do
        local f = GetFlashlightMaterial(src)
        if f then
            SetFlashlightConstants(f.mat, GetSettings(src), f.isFace)
            overrides[idx] = f.mat
            any = true
        else
            overrides[idx] = skipOutline
        end
    end
    if not any then return end

    render.RenderFlashlights(function()
        DrawPopulator(ent, LightProbePos(ent), populatorFlashlightMaterial)   -- commits this flashlight's data
        for idx, m in pairs(overrides) do render_MaterialOverrideByIndex(idx, m) end
        DrawModel(ent, flags)
        for idx in pairs(overrides) do render_MaterialOverrideByIndex(idx, nil) end
    end)
end

local flashlightErrorShown = false
local function DrawFlashlights(ent, flags)
    render_OverrideDepthEnable(true, false)
    local ok, err = pcall(DrawFlashlightPasses, ent, flags)
    if not ok then
        for i = 0, #ent:GetMaterials() - 1 do render_MaterialOverrideByIndex(i, nil) end
        if not flashlightErrorShown then
            flashlightErrorShown = true
            ErrorNoHalt("[ZZZ Shader] flashlight pass failed: " .. tostring(err) .. "\n")
        end
    end
    render_OverrideDepthEnable(true, true)
end

---------------------------------------------------------------------------
-- RenderOverride
---------------------------------------------------------------------------
local lply = NULL
hook.Add("InitPostEntity", "ZZZ_InitPostEntity", function() lply = LocalPlayer() end)

local function ZZZRenderOverride(self, flags)
    -- Avoid drawing the PAC3 local player twice
    if self.pac_is_drawing and not self.pac_drawing_model and self == lply then return end

    DrawPopulator(self, LightProbePos(self))

    render_OverrideDepthEnable(true, true)
    local prev = self.ZZZ_PrevRenderOverride
    if prev then prev(self, flags) else DrawModel(self, flags) end

    if cv_hair_shadow:GetBool() then DrawHairShadow(self, flags) end
    if cv_outline:GetBool() then DrawOutline(self, flags) end
    if cv_flashlight:GetBool() then DrawFlashlights(self, flags) end
    render_OverrideDepthEnable(false, false)
end

---------------------------------------------------------------------------
-- Material proxy
---------------------------------------------------------------------------
local FALLBACK_BODY = {
    ["$texture1"] = "neutral_lightmap",
    ["$texture2"] = "neutral_normal",
    ["$texture3"] = "neutral_materialmap",
    ["$texture4"] = "toon_ramp",
    ["$texture5"] = "metal_matcap",
    ["$texture7"] = "black",
}

-- Face: a missing face shadow map falls back to black (alpha 0 = plain normal-based shading)
local FALLBACK_FACE = {
    ["$texture1"] = "black",
    ["$texture4"] = "toon_ramp",
}

local VMATRIX = Matrix()
local white = Vector(1, 1, 1)

local function ParseColor(str)
    if not str then return white end
    local v = Vector((string.gsub(tostring(str), "[%[%]{}]", "")))
    return v:LengthSqr() > 0 and v or white
end

local proxy = {
    init = function(self, mat, values)
        mat:SetFloat("$vertexnormal", 1)
        if (mat:GetString("$vertexshader") or "") == "" then mat:SetString("$vertexshader", "zzz_body_vs30") end
        if (mat:GetString("$pixshader") or "") == "" then mat:SetString("$pixshader", "zzz_body_ps30") end
        mat:SetInt("$linearread_texture1", 1)
        mat:SetInt("$linearread_texture2", 1)
        mat:SetInt("$linearread_texture3", 1)

        self.isFace = string.StartsWith(mat:GetString("$pixshader") or "", "zzz_face")
        for key, file in pairs(self.isFace and FALLBACK_FACE or FALLBACK_BODY) do
            local tex = mat:GetTexture(key)
            if not tex or tex:IsErrorTexture() then
                mat:SetTexture(key, COMMON .. file)
            end
        end

        -- Per-material settings from the proxy block
        self.intensity    = tonumber(values.intensity) or 1
        self.shadow       = tonumber(values.shadowstrength) or 1
        self.rim          = tonumber(values.rimstrength) or 1
        self.spec         = tonumber(values.specstrength) or 1
        self.matcap       = tonumber(values.matcapstrength) or 1
        self.maxLight     = tonumber(values.maxlight)             -- nil = use zzz_max_light
        self.specPower    = tonumber(values.specpower)            -- nil = use zzz_spec_power
        self.matcapMode   = tonumber(values.matcapmode) or 0      -- 0 replace, 1 add, 2 multiply (ZZZ _MatCapBlendMode)
        self.rimWidth     = tonumber(values.rimwidth) or 3.5      -- ZZZ _FresnelWidth
        self.emission     = tonumber(values.emissionscale) or 1
        self.alphaMode    = tonumber(values.alphamode) or 0
        self.tint         = ParseColor(values.colortint)
        -- Face only
        self.faceShadow   = tonumber(values.faceshadow) or 1
        self.nose         = tonumber(values.noseline) or tonumber(values.nosehighlight) or 1
        -- ZZZ _NoseLineHoriDisp / _NoseLineLkDnDisp, packed into one float: floor = side x 1000, frac = down
        local noseSide    = math.Clamp(tonumber(values.noselineside) or 0.8522, 0, 1)
        local noseDown    = math.Clamp(tonumber(values.noselinedown) or 0.62, 0, 0.999)
        self.nosePacked   = math.floor(noseSide * 1000 + 0.5) + noseDown
        self.flip         = tonumber(values.flipfacemap) or 0
        self.rampRow      = tonumber(values.ramprow) or 0
        self.headBone     = values.headbone or "ValveBiped.Bip01_Head1"
        self.headFwd      = ParseAxis(values.headforward)
        self.headRight    = ParseAxis(values.headright)
        self.emissionTint = ParseColor(values.emissiontint)

        -- Read back by the outline and hair shadow code.
        -- Hair shadow: on a face, how strongly it receives (default 1); on a body/hair material,
        -- 1 = casts (default: materials whose name contains "hair")
        local castDefault = string.find(string.lower(mat:GetName()), "hair", 1, true) and 1 or 0
        matSettings[mat:GetName()] = {
            outline    = tonumber(values.outline) or 1,
            alphaMode  = self.alphaMode,
            rampRow    = self.rampRow,
            hairShadow = tonumber(values.hairshadow) or (self.isFace and 1 or castDefault),
            intensity  = self.intensity,
            shadow     = self.shadow,
            maxLight   = tonumber(values.maxlight),
        }
    end,

    bind = function(self, mat, ent)
        if not IsValid(ent) then return end

        if ent.RenderOverride ~= ZZZRenderOverride then
            ent.ZZZ_PrevRenderOverride = ent.RenderOverride
            ent.RenderOverride = ZZZRenderOverride
        end

        -- Faces record what they send, for the hair shadow pass's copy of the material
        local rec
        if self.isFace then
            local st = matSettings[mat:GetName()]
            if st then
                st.bound = st.bound or { c = {} }
                rec = st.bound
            end
        end
        local function SetC(key, v)
            mat:SetFloat(key, v)
            if rec then rec.c[key] = v end
        end

        -- c0: intensity, cel softness, cel threshold, rim
        SetC("$c0_x", cv_intensity:GetFloat() * self.intensity)
        SetC("$c0_y", cv_softness:GetFloat())
        SetC("$c0_z", cv_threshold:GetFloat())
        SetC("$c0_w", cv_rim:GetFloat() * self.rim)

        if self.isFace then
            -- c1/c2: head forward/right + face shadow strength / nose highlight
            local fwd, right = GetHeadVectors(ent, self.headBone, self.headFwd, self.headRight)
            SetC("$c1_x", fwd.x)
            SetC("$c1_y", fwd.y)
            SetC("$c1_z", fwd.z)
            SetC("$c1_w", self.faceShadow)
            SetC("$c2_x", right.x)
            SetC("$c2_y", right.y)
            SetC("$c2_z", right.z)
            SetC("$c2_w", self.nose)
            -- c3: alpha mode, flip, ramp row, shadow strength
            SetC("$c3_x", self.alphaMode)
            SetC("$c3_y", self.flip)
            SetC("$c3_z", self.rampRow)
            SetC("$c3_w", cv_shadow:GetFloat() * self.shadow)
        else
            -- c1: specular, matcap blend mode, max light, specular power
            mat:SetFloat("$c1_x", cv_spec:GetFloat() * self.spec)
            mat:SetFloat("$c1_y", self.matcapMode)
            mat:SetFloat("$c1_z", EffectiveMaxLight(self.maxLight))
            mat:SetFloat("$c1_w", math.max(self.specPower or cv_spec_power:GetFloat(), 1))
            -- c3: alpha mode, emission, matcap, shadow strength
            mat:SetFloat("$c3_x", self.alphaMode)
            mat:SetFloat("$c3_y", self.emission)
            mat:SetFloat("$c3_z", self.matcap)
            mat:SetFloat("$c3_w", cv_shadow:GetFloat() * self.shadow)
        end

        -- c11-c18: ambient cube (+X,-X,+Y,-Y | +Z,-Z) with the fog flag, manual key light and rim width
        -- in the spare .w slots, then tint * colour modulation + blend, emission tint + nose line (face)
        local a = GetAmbientCube(ent)
        local fog = render_GetFogMode() ~= MATERIAL_FOG_NONE and 1 or 0
        local keyDir, keyPower = GetKeyLight()
        local m1 = {
            a[1].x, a[1].y, a[1].z, fog,
            a[2].x, a[2].y, a[2].z, keyDir.x,
            a[3].x, a[3].y, a[3].z, keyDir.y,
            a[4].x, a[4].y, a[4].z, keyDir.z }
        VMATRIX:SetUnpacked(unpack(m1))
        mat:SetMatrix("$viewprojmat", VMATRIX)

        local mr, mg, mb = render_GetColorModulation()
        local t, e = self.tint, self.emissionTint
        local m2 = {
            a[5].x, a[5].y, a[5].z, keyPower,
            a[6].x, a[6].y, a[6].z, self.rimWidth,
            t.x * mr, t.y * mg, t.z * mb, render_GetBlend(),
            self.isFace and EffectiveMaxLight(self.maxLight) or e.x, e.y, e.z,
            self.isFace and self.nosePacked or 0 }
        VMATRIX:SetUnpacked(unpack(m2))
        mat:SetMatrix("$invviewprojmat", VMATRIX)

        if rec then rec.m1, rec.m2 = m1, m2 end
    end,
}

proxy.name = "ZZZ"
matproxy.Add(proxy)
-- Old name, so existing materials keep working
matproxy.Add(table.Merge(table.Copy(proxy), { name = "ZZZLightingProxy" }))

print("[ZZZ Shader] ZZZ material proxy registered.")
