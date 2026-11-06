// ZZZ flashlight / projected texture pass (additive), for body, hair and face.
//
// Drawn by Lua inside render.RenderFlashlights, once per projected texture, right after a PLAIN
// VertexLitGeneric populator (no $phong / $bumpmap) has been drawn in flashlight mode. That draw
// leaves the flashlight's data in registers screenspace_general_8tex never writes
// (SDK 2013 vertexlitgeneric_dx9_helper.cpp, verified in game with zzz_flashlight_probe):
//   c22 attenuation (constant, linear, quadratic, farZ)   c23 flashlight position
//   c24-c27 world -> flashlight texture matrix             c28 flashlight colour
// The engine's cookie (s7) and shadow map (s8) do NOT survive, so the cookie comes from this
// material's $texture7 (or a procedural soft circle) and there are no flashlight shadows.
// c11-c18 hold 8tex's identity matrices here, so nothing from zzz_lighting_ps.h that reads them
// is used (ZZZ_FLASHLIGHT_PASS).

#define ZZZ_FLASHLIGHT_PASS 1
#include "zzz_lighting_ps.h"

sampler DiffuseSampler     : register(s0); // $basetexture  _D (body/hair/face)
sampler LightMapSampler    : register(s1); // $texture1     _M (body/hair; unused on faces)
sampler NormalMapSampler   : register(s2); // $texture2     _N (body/hair)
sampler MaterialMapSampler : register(s3); // $texture3     _A (alphamode 2)
sampler RampSampler        : register(s4); // $texture4     toon ramp
sampler CookieSampler      : register(s7); // $texture7     flashlight cookie (when c2.x = 1)

const float4 cParams0 : register(c0); // x intensity, y cel softness, z cel threshold, w flashlight strength
const float4 cParams1 : register(c1); // x use normal map (0/1), y ramp row (-1 = from LightMap.R), z alpha mode, w max light
const float4 cParams2 : register(c2); // x cookie (1 = $texture7, 0 = procedural soft circle), y shadow strength

const float4   cFlAtten          : register(c22);
const float4   cFlPos            : register(c23);
const float4x4 cFlWorldToTexture : register(c24);
const float4   cFlColor          : register(c28);

float4 main(PS_INPUT i) : COLOR {
	float4 albedo = tex2D(DiffuseSampler, i.uv);
	float3 worldPos = i.worldPosFog.xyz;

	// --- Where the pixel falls in the beam
	float4 fs   = mul(float4(worldPos, 1.0), cFlWorldToTexture);
	float3 proj = fs.xyz / max(fs.w, 1e-5);
	float  inFront = (fs.w > 0.0) ? 1.0 : 0.0;
	float3 cookie;
	if (cParams2.x > 0.5) {
		float inside = (proj.x >= 0.0 && proj.x <= 1.0 && proj.y >= 0.0 && proj.y <= 1.0) ? 1.0 : 0.0;
		cookie = tex2D(CookieSampler, proj.xy).rgb * inside;
	} else {
		float r = length(proj.xy - 0.5) * 2.0;
		cookie = (1.0 - smoothstep(0.7, 1.0, r)).xxx;
	}
	cookie *= inFront;

	// --- Source's flashlight falloff (common_flashlight_fxc.h): c + l/d + q/d^2, faded out over the
	// last 40% of farZ
	float3 delta = cFlPos.xyz - worldPos;
	float  dist  = max(length(delta), 1e-3);
	float3 L     = delta / dist;
	float  atten = saturate(dot(cFlAtten.xyz, float3(1.0, 1.0 / dist, 1.0 / (dist * dist))));
	float  farZ  = max(cFlAtten.w, 1.0);
	atten *= saturate((farZ - dist) / (0.4 * farZ));

	// --- Normal (same as zzz_body_ps30 when a normal map is used)
	float3 Nv = normalize(i.worldNormal);
	float3 N  = Nv;
	float4 lightMap = tex2D(LightMapSampler, i.uv);
	if (cParams1.x > 0.5) {
		float3 T = normalize(i.worldTangent.xyz - Nv * dot(i.worldTangent.xyz, Nv));
		float3 B = cross(Nv, T) * i.worldTangent.w;
		float2 nXY = tex2D(NormalMapSampler, i.uv).rg * 2.0 - 1.0;
		float  nZ  = sqrt(saturate(1.0 - dot(nXY, nXY)));
		N = normalize(T * nXY.x + B * nXY.y + Nv * nZ);
	}

	// --- Toon: the flashlight only lights the side facing it, banded through the material's ramp
	float softness   = max(cParams0.y, 0.001);
	float lightValue = (dot(N, L) * 0.5 + 0.5) - cParams0.z + 0.5;
	float cel        = smoothstep(0.5 - softness, 0.5 + softness, lightValue);
	float row        = (cParams1.y >= 0.0) ? cParams1.y : RampRowFromLightMap(lightMap.r);
	float3 ramp      = SampleRamp(RampSampler, lightValue, row, cParams2.y);

	float3 light = CapLight(cFlColor.rgb * atten * cookie * cParams0.x * cParams0.w, cParams1.w);
	float3 color = albedo.rgb * ramp * light * cel;

	// --- Alpha: cutouts are discarded, blended parts fade the added light
	if (cParams1.z > 1.5)      color *= tex2D(MaterialMapSampler, i.uv).r;
	else if (cParams1.z > 0.5) clip(albedo.a - 0.5);

	float lightScale = (LINEAR_LIGHT_SCALE > 1e-4) ? LINEAR_LIGHT_SCALE : 1.0;
	color *= lightScale * i.worldPosFog.w;   // fades out in fog, like Source's flashlight (fog to black)
	return FinalOutput(float4(color, 1.0), 0, PIXEL_FOG_TYPE_NONE, TONEMAP_SCALE_NONE);
}
