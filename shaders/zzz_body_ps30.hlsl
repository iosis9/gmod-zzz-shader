// ZZZ NPR body / hair pixel shader (screenspace_general_8tex)
//
// Texture layout follows the in-game ZZZ character textures
// (https://leotorrez.github.io/modding/guides/zzz-textures):
//   _D  Diffuse       sRGB  RGB albedo, A optional alpha
//   _M  LightMap      lin   R shadow-ramp / outline region (up to 5 levels), G metallic, B gloss
//   _N  NormalMap     lin   RG tangent normal, B occlusion
//   _A  MaterialMap   lin   R transparency, G secondary metallic (spec tint), B specular mask
//
// All engine lights + ambient cube are folded into one weighted cel value (zzz_lighting_ps.h),
// which is looked up on the ramp row picked by LightMap.R.

#include "zzz_lighting_ps.h"

sampler DiffuseSampler     : register(s0); // $basetexture  _D
sampler LightMapSampler    : register(s1); // $texture1     _M
sampler NormalMapSampler   : register(s2); // $texture2     _N
sampler MaterialMapSampler : register(s3); // $texture3     _A
sampler RampSampler        : register(s4); // $texture4     toon ramp, 5 rows selected by LightMap.R
sampler MatCapSampler      : register(s5); // $texture5     matcap (RGB colour, A blend weight), e.g. Eff_MatCap_007
// s6 ($texture6) is no longer used: the rim is a fresnel power (c16.w)
sampler EmissionSampler    : register(s7); // $texture7     _E (RGB colour, A mask)

const float4 cParams0 : register(c0); // x intensity, y cel softness, z cel threshold, w rim strength
const float4 cParams1 : register(c1); // x specular strength, y matcap blend mode (0 replace, 1 add, 2 multiply), z max light (1e4 = off), w specular power (highlight size; higher = smaller)
const float4 cParams3 : register(c3); // x alpha mode (0 opaque, 1 _D.a, 2 _A.r), y emission scale, z matcap strength, w shadow strength

float4 main(PS_INPUT i) : COLOR {
	float4 albedo    = tex2D(DiffuseSampler, i.uv);
	float4 lightMap  = tex2D(LightMapSampler, i.uv);
	float4 normalTex = tex2D(NormalMapSampler, i.uv);
	float4 matMap    = tex2D(MaterialMapSampler, i.uv);
	float4 emitTex   = tex2D(EmissionSampler, i.uv);

	float3 worldPos = i.worldPosFog.xyz;
	float3 V = normalize(cEyePos - worldPos);

	// --- Normal: RG tangent XY, Z reconstructed, B is occlusion
	float3 Nv = normalize(i.worldNormal);
	float3 T  = normalize(i.worldTangent.xyz - Nv * dot(i.worldTangent.xyz, Nv));
	float3 B  = cross(Nv, T) * i.worldTangent.w;
	float2 nXY = normalTex.rg * 2.0 - 1.0;
	float  nZ  = sqrt(saturate(1.0 - dot(nXY, nXY)));
	float3 N   = normalize(T * nXY.x + B * nXY.y + Nv * nZ);
	float  occlusion = normalTex.b;

	LightResult lit = GatherLights(N, worldPos, i.lightAtten);
	float3 L = lit.keyDir;

	// --- Ramp. LightMap.R picks the ZZZ material slot (ramp row); the continuous light value is the U,
	// so the ramp's own bands (lit / shallow / shadow, with fade edges) do the cel shading.
	// The hard cel value is only used to mask specular and rim to the lit side.
	float softness = max(cParams0.y, 0.001);
	float lightValue = lit.shade * occlusion - cParams0.z + 0.5;   // c0.z threshold moves the terminator
	float cel = smoothstep(0.5 - softness, 0.5 + softness, lightValue);
	float rampRow = RampRowFromLightMap(lightMap.r);
	float3 ramp = SampleRamp(RampSampler, lightValue, rampRow, cParams3.w);

	float3 light = CapLight(lit.incident * cParams0.x, cParams1.z);
	float3 diffuse = albedo.rgb * ramp * light;

	// --- Matcap, masked by LightMap.G (ZZZ _UseMatCapMask). The slot's colour burst scales the matcap,
	// its alpha burst scales the matcap's alpha into the blend weight.
	float3 up    = (abs(V.z) > 0.99) ? float3(0, 1, 0) : float3(0, 0, 1);
	float3 right = normalize(cross(up, V));
	float3 vUp   = cross(V, right);
	float2 mcUV  = float2(dot(N, right), -dot(N, vUp)) * 0.5 + 0.5;
	float4 matcap = tex2D(MatCapSampler, mcUV);
	float2 burst  = SampleMatCapBurst(RampSampler, rampRow);
	float3 mcColor = matcap.rgb * burst.x;
	float  mcWeight = saturate(matcap.a * burst.y) * saturate(lightMap.g) * cParams3.z;
	float3 mcTarget;
	if (cParams1.y > 1.5)      mcTarget = diffuse * mcColor;                 // 2 multiply
	else if (cParams1.y > 0.5) mcTarget = diffuse + mcColor * light;         // 1 add
	else                       mcTarget = albedo.rgb * mcColor * light;      // 0 replace the shading
	float3 color = lerp(diffuse, mcTarget, mcWeight);

	// --- Stylised specular: LightMap.B amount, MaterialMap.B mask, MaterialMap.G tints it by albedo.
	// Per slot: _SpecularRange scales the highlight size, _ToonSpecular is its edge softness.
	float4 specData  = SampleSlotData(RampSampler, rampRow, 5);   // rgb colour, a toon softness x 4
	float  specRange = SampleSlotData(RampSampler, rampRow, 6).a * 4.0;
	float  toonSoft  = max(specData.a * 0.25, 0.001);
	float3 H = normalize(L + V);
	// LightMap.B is the highlight AMOUNT (0 = none): on the hair it's black except for the painted
	// shine marks. The highlight's size is a separate setting (c1.w, zzz_spec_power / specpower).
	float  glossAmount = smoothstep(0.0, 0.25, lightMap.b);
	float  specPow = cParams1.w / max(specRange, 0.01);
	float  spec = pow(saturate(dot(N, H)), specPow);
	spec = smoothstep(0.5 - toonSoft, 0.5 + toonSoft, spec) * matMap.b * glossAmount * cel;
	float3 specColor = specData.rgb * lerp(float3(1, 1, 1), albedo.rgb, saturate(matMap.g));
	color += spec * specColor * light * cParams1.x;

	// --- Rim (fresnel, _FresnelWidth) on the lit side
	float rim = RimFresnel(N, V);
	color += rim * cel * cParams0.w * light * lerp(float3(1, 1, 1), albedo.rgb, 0.5) * 0.5;

	// --- Emission (_E) is unlit
	color += emitTex.rgb * emitTex.a * cParams3.y * cEmissionTint.rgb;

	// 1: cutout, discarded here (GMod doesn't reliably alpha-test). 2: blended, needs $alpha_blend 1.
	float alpha = 1.0;
	if (cParams3.x > 1.5)      alpha = matMap.r;
	else if (cParams3.x > 0.5) { alpha = albedo.a; clip(alpha - 0.5); }

	return FinishColor(color, alpha, i.worldPosFog.w);
}
