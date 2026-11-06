// Shared lighting for the ZZZ pixel shaders.
//
// Engine data (see AGENTS.md):
//   c11-c16  ambient cube +X,-X,+Y,-Y,+Z,-Z (rgb), via $viewprojmat / $invviewprojmat
//            c11.w fog enabled, c12.w/c13.w/c14.w manual key light dir, c15.w manual key strength,
//            c16.w rim width (_FresnelWidth exponent)
//   c17      rgb tint * colour modulation, w render blend
//   c18      rgb emission tint, w face only: nose line thresholds (see zzz_face_ps30).
//            Face only: x = max light (the face has no emission, so it borrows that slot)
//   c20-c25  engine lights left by the populator draw (light 3 packed in .w)
//   TEXCOORD4 per-light attenuation from zzz_body_vs30

#include "common_ps_fxc.h"

// zzz_flashlight_ps30 defines ZZZ_FLASHLIGHT_PASS: it reads the flashlight's data from c22-c28
// instead, and its c11-c18 hold 8tex's identity matrices, so the engine-light / ambient-cube
// constants and everything that reads them are left out.
#ifndef ZZZ_FLASHLIGHT_PASS
const float4 cAmbientCube[6] : register(c11);
const float4 cColorTint      : register(c17);
const float4 cEmissionTint   : register(c18);

struct PixelLight { float4 color; float4 pos; };
const PixelLight cLightInfo[3] : register(c20);
#endif

static const float3 MANUAL_KEY_COLOR = float3(1.0, 0.92, 0.9); // ZZZ's _UISunColor

struct PS_INPUT {
	float2 uv           : TEXCOORD0;
	float3 worldNormal  : TEXCOORD1;
	float4 worldTangent : TEXCOORD2;
	float4 worldPosFog  : TEXCOORD3;
	float4 lightAtten   : TEXCOORD4;
};

struct LightResult {
	float  shade;     // luminance-weighted half-Lambert of all lights, 0..1
	float3 incident;  // total light reaching the surface, ignoring direction
	float3 keyDir;    // luminance-weighted light direction (normalised)
};

float Luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

#ifndef ZZZ_FLASHLIGHT_PASS
void AddLight(float3 N, float3 L, float3 radiance,
              inout float shadeSum, inout float weightSum, inout float3 incident, inout float3 keyDir) {
	float w = Luma(radiance);
	shadeSum  += w * (dot(N, L) * 0.5 + 0.5);
	weightSum += w;
	incident  += radiance;
	keyDir    += L * w;
}

LightResult GatherLights(float3 N, float3 worldPos, float4 atten) {
	float  shadeSum = 0, weightSum = 0;
	float3 incident = 0, keyDir = 0;

	float3 light3Color = float3(cLightInfo[0].color.w, cLightInfo[0].pos.w, cLightInfo[1].color.w);
	float3 light3Pos   = float3(cLightInfo[1].pos.w,   cLightInfo[2].color.w, cLightInfo[2].pos.w);

	AddLight(N, normalize(cLightInfo[0].pos.xyz - worldPos), cLightInfo[0].color.rgb * atten.x, shadeSum, weightSum, incident, keyDir);
	AddLight(N, normalize(cLightInfo[1].pos.xyz - worldPos), cLightInfo[1].color.rgb * atten.y, shadeSum, weightSum, incident, keyDir);
	AddLight(N, normalize(cLightInfo[2].pos.xyz - worldPos), cLightInfo[2].color.rgb * atten.z, shadeSum, weightSum, incident, keyDir);
	AddLight(N, normalize(light3Pos - worldPos),             light3Color             * atten.w, shadeSum, weightSum, incident, keyDir);

	// Optional manual key light (zzz_light_override)
	float3 manualDir = float3(cAmbientCube[1].w, cAmbientCube[2].w, cAmbientCube[3].w);
	AddLight(N, normalize(manualDir + float3(0, 0, 1e-4)), MANUAL_KEY_COLOR * cAmbientCube[4].w,
	         shadeSum, weightSum, incident, keyDir);

	// Ambient cube: its average brightness, plus its directionality as a soft light
	float3 ambAvg = (cAmbientCube[0].xyz + cAmbientCube[1].xyz + cAmbientCube[2].xyz +
	                 cAmbientCube[3].xyz + cAmbientCube[4].xyz + cAmbientCube[5].xyz) / 6.0;
	float3 ambGrad = float3(Luma(cAmbientCube[0].xyz) - Luma(cAmbientCube[1].xyz),
	                        Luma(cAmbientCube[2].xyz) - Luma(cAmbientCube[3].xyz),
	                        Luma(cAmbientCube[4].xyz) - Luma(cAmbientCube[5].xyz));
	float3 ambDir = normalize(ambGrad + float3(0, 0, 1e-3));
	float  ambW   = Luma(ambAvg);
	float  ambDirectionality = saturate(length(ambGrad) / max(ambW * 2.0, 1e-4));
	shadeSum  += ambW * lerp(0.5, dot(N, ambDir) * 0.5 + 0.5, ambDirectionality);
	weightSum += ambW;
	incident  += ambAvg;
	keyDir    += ambDir * ambW * 0.5;

	LightResult r;
	r.shade    = (weightSum > 1e-5) ? shadeSum / weightSum : 1.0;
	r.incident = incident;
	r.keyDir   = normalize(keyDir + float3(0, 0, 1e-4));
	return r;
}
#endif

// Soft cap on the total light's brightness (luminance), keeping its colour. Light below 75% of
// maxLight is untouched, so shaded areas and dim rooms look the same; above that it eases toward
// maxLight and never passes it. Lua sends a huge value (1e4) when the cap is off.
float3 CapLight(float3 light, float maxLight) {
	float lum = Luma(light);
	float knee = maxLight * 0.75;
	if (lum <= knee) return light;
	float room = maxLight - knee;
	float capped = knee + room * (1.0 - exp(-(lum - knee) / room));
	return light * (capped / lum);
}

// Ramp layout (tools/zzz_ramp_from_json.py): 256x8
//   rows 0-4  ZZZ material slots 1-5. U = light value, lit above 0.5:
//             0-0.25 shadow, 0.25 shadow-fade edge, 0.25-0.5 shallow, 0.5 shallow-fade edge, then lit
//   row 5     RGB specular colour per slot, A = _ToonSpecular x 4
//   row 6     RGB outline colour per slot / 2, A = _SpecularRange / 4
//   row 7     A in 10 bins: _MatCapColorBurst / 4 (slots 1-5), _MatCapAlphaBurst / 4 (slots 1-5)
// RGB is read as sRGB; the numbers are in alpha, which is always linear.
// LightMap.R picks the slot in reverse: R 1.0 -> slot 1 ... R 0 -> slot 5
float RampRowFromLightMap(float r) { return floor((1.0 - saturate(r)) * 4.0 + 0.5); }

float3 SampleRamp(sampler rampSampler, float u, float row, float shadowStrength) {
	float3 ramp = tex2D(rampSampler, float2(saturate(u), (row + 0.5) / 8.0)).rgb;
	return lerp(float3(1, 1, 1), ramp, saturate(shadowStrength));
}

float4 SampleSlotData(sampler rampSampler, float row, float dataRow) {
	return tex2D(rampSampler, float2((row + 0.5) / 5.0, (dataRow + 0.5) / 8.0));
}

// x = matcap colour burst, y = matcap alpha burst
float2 SampleMatCapBurst(sampler rampSampler, float row) {
	float colorBurst = tex2D(rampSampler, float2((row + 0.5) / 10.0, 7.5 / 8.0)).a;
	float alphaBurst = tex2D(rampSampler, float2((row + 5.5) / 10.0, 7.5 / 8.0)).a;
	return float2(colorBurst, alphaBurst) * 4.0;
}

#ifndef ZZZ_FLASHLIGHT_PASS
// ZZZ _FresnelWidth: rim = (1 - N.V) ^ width (c16.w). Larger = thinner rim.
float RimFresnel(float3 N, float3 V) {
	return pow(1.0 - saturate(dot(N, V)), max(cAmbientCube[5].w, 0.01));
}

// HDR scale, fog, tint and blend; the engine's alpha test discards alpha == 0
float4 FinishColor(float3 color, float alpha, float fogVisibility) {
	color *= cColorTint.rgb;
	alpha *= cColorTint.w;
	float lightScale = (LINEAR_LIGHT_SCALE > 1e-4) ? LINEAR_LIGHT_SCALE : 1.0;
	color *= lightScale;
	if (cAmbientCube[0].w > 0.5)
		color = lerp(g_LinearFogColor.rgb, color, fogVisibility);
	return FinalOutput(float4(color, alpha), 0, PIXEL_FOG_TYPE_NONE, TONEMAP_SCALE_NONE);
}
#endif
