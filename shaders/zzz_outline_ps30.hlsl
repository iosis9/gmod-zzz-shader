// ZZZ inverted-hull outline pixel shader
// Outline colour = darkened diffuse * the material slot's _OutlineColor (ramp row 6), as in ZZZ
// (skin slots get a reddish outline, hair a bluish one).

#include "common_ps_fxc.h"

sampler DiffuseSampler  : register(s0); // $basetexture, copied from the body material by the Lua proxy
sampler LightMapSampler : register(s1); // $texture1, the body's LightMap (R picks the slot)
sampler RampSampler     : register(s4); // $texture4, the body's ramp (row 6 = outline colour per slot, stored / 2)

const float4 cParams0 : register(c0); // x darken factor, y flat-colour mix, z fog enabled, w alpha mode (see below)
const float4 cParams1 : register(c1); // xyz flat outline colour
const float4 cParams2 : register(c2); // xyz light level at the entity (average ambient cube * intensity), set per draw by Lua
const float4 cParams3 : register(c3); // x slot row override (>= 0, e.g. faces) or -1 = from LightMap.R

struct PS_INPUT {
	float2 uv  : TEXCOORD0;
	float  fog : TEXCOORD1;
};

float4 main(PS_INPUT i) : COLOR {
	float4 albedo = tex2D(DiffuseSampler, i.uv);

	float row = (cParams3.x >= 0.0) ? cParams3.x
	                                : floor((1.0 - saturate(tex2D(LightMapSampler, i.uv).r)) * 4.0 + 0.5);
	float3 slotTint = tex2D(RampSampler, float2((row + 0.5) / 5.0, 6.5 / 8.0)).rgb * 2.0;

	// Lit like the body (albedo * light), so the outline darkens with the model in shadowed areas
	float3 color = lerp(albedo.rgb * cParams0.x * slotTint, cParams1.rgb, saturate(cParams0.y)) * cParams2.rgb;

	float lightScale = (LINEAR_LIGHT_SCALE > 1e-4) ? LINEAR_LIGHT_SCALE : 1.0;
	color *= lightScale;
	if (cParams0.z > 0.5)
		color = lerp(g_LinearFogColor.rgb, color, i.fog);

	// w: 0 opaque, 1 diffuse alpha, 2 skip (alpha 0, discarded by the engine's alpha test; used for non-ZZZ submaterials)
	float alpha = (cParams0.w > 1.5) ? 0.0 : ((cParams0.w > 0.5) ? albedo.a : 1.0);
	if (cParams0.w > 0.5) clip(alpha - 0.5);   // discard in the shader; GMod doesn't reliably alpha-test
	return FinalOutput(float4(color, alpha), 0, PIXEL_FOG_TYPE_NONE, TONEMAP_SCALE_NONE);
}
