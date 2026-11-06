// ZZZ NPR face pixel shader (screenspace_general_8tex)
//
// ZZZ faces are not shaded from their normals. A face shadow map (e.g. Female_Face_Lightmap) holds,
// per face-UV texel, the light angle at which that texel turns lit:
//   R  threshold gradient across the whole face (0 one side .. 1 other side, ~0.5 down the middle)
//   G  unknown (0.5 almost everywhere, one patch near an eye) - not used
//   B  nose line mask (a small mark on one side of the nose, mirrored for the other side)
//   A  where the face shadow applies (0 = fall back to normal-based shading)
//
// Nose line (ZZZ _NoseLineHoriDisp / _NoseLineLkDnDisp): shown only when the camera is off to the
// side (cos of the horizontal view angle below the side threshold) or above the face (cos of the
// vertical view angle below the down threshold). c18.w packs both: floor(w) = side x 1000,
// frac(w) = down. It's drawn in the slot's shadow tone on the side of the nose away from the camera.
//
// t = horizontal light angle around the head / 180 deg  (0 = front, +-1 = behind, + = head's right)
//   t < 0 : lit where R <= 1 + t
//   t >= 0: lit where R >= t
// so a frontal light lights everything, a 90 deg side light lights exactly that half, and a
// light from behind leaves the face in shadow.

#include "zzz_lighting_ps.h"

sampler DiffuseSampler  : register(s0); // $basetexture  face _D
sampler FaceMapSampler  : register(s1); // $texture1     face shadow map (linear)
sampler RampSampler     : register(s4); // $texture4     toon ramp

const float4 cParams0 : register(c0); // x intensity, y cel softness, z cel threshold, w rim strength
const float4 cParams1 : register(c1); // xyz head forward (world), w face shadow strength
const float4 cParams2 : register(c2); // xyz head right (world),   w nose line strength
const float4 cParams3 : register(c3); // x alpha mode (0 opaque, 1 _D.a), y flip map (0/1), z ramp row, w shadow strength

static const float PI = 3.14159265;

float4 main(PS_INPUT i) : COLOR {
	float4 albedo  = tex2D(DiffuseSampler, i.uv);
	float4 faceMap = tex2D(FaceMapSampler, i.uv);

	float3 worldPos = i.worldPosFog.xyz;
	float3 V = normalize(cEyePos - worldPos);
	float3 N = normalize(i.worldNormal);

	LightResult lit = GatherLights(N, worldPos, i.lightAtten);
	float softness = max(cParams0.y, 0.001);

	// --- Normal-based cel value (used outside the face map's alpha mask)
	float normalCel = smoothstep(cParams0.z - softness, cParams0.z + softness, lit.shade);

	// --- Face shadow map
	float3 headFwd   = normalize(cParams1.xyz + float3(1e-5, 0, 0));
	float3 headRight = normalize(cParams2.xyz + float3(0, 1e-5, 0));
	float3 L = lit.keyDir;
	float  lx = dot(L, headRight);
	float  lz = dot(L, headFwd);
	float  t  = atan2(lx, lz) / PI;
	// A light from (nearly) straight above/below has no meaningful side: treat it as frontal
	t *= saturate(length(float2(lx, lz)) * 2.0);
	if (cParams3.y > 0.5) t = -t;

	float threshold = faceMap.r;
	float signedDist = (t < 0.0) ? (1.0 + t) - threshold : threshold - t;
	float sdfCel = smoothstep(-softness, softness, signedDist);

	float faceMask = saturate(faceMap.a * cParams1.w);
	float cel = lerp(normalCel, sdfCel, faceMask);
#ifdef ZZZ_HAIR_SHADOW
	cel = 0.0;   // zzz_faceshadow_ps30: under the hair shadow everything sits in the shadow band
#endif

	// Shadowed face sits in the ramp's shallow band (ZZZ faces never go to deep shadow)
	float3 ramp  = SampleRamp(RampSampler, lerp(0.375, 1.0, cel), cParams3.z, cParams3.w);
	float3 light = CapLight(lit.incident * cParams0.x, cEmissionTint.x);   // faces borrow the emission tint slot for the cap
	float3 color = albedo.rgb * ramp * light;

	// --- Nose line (B), by view angle around the head
	float3 headUp = cross(headRight, headFwd);
	float  vx = dot(V, headRight), vy = dot(V, headUp), vz = dot(V, headFwd);
	float  sideCos = vz / max(length(float2(vx, vz)), 1e-4);
	float  downCos = vz / max(length(float2(vy, vz)), 1e-4);
	float  sideThreshold = floor(cEmissionTint.w) / 1000.0;
	float  downThreshold = frac(cEmissionTint.w);
	float  noseVis = max(1.0 - smoothstep(sideThreshold - 0.03, sideThreshold + 0.03, sideCos),
	                     (vy > 0.0) ? 1.0 - smoothstep(downThreshold - 0.03, downThreshold + 0.03, downCos) : 0.0);
	// The mask is drawn on the head's left (U < 0.5); mirror it when the camera is on the left
	bool   camLeft = (vx < 0.0) != (cParams3.y > 0.5);
	float  noseMask = tex2D(FaceMapSampler, camLeft ? float2(1.0 - i.uv.x, i.uv.y) : i.uv).b;
	float3 noseTone = SampleRamp(RampSampler, 0.1, cParams3.z, 1.0);
	color *= lerp(float3(1, 1, 1), noseTone, saturate(noseMask * noseVis * faceMask * cParams2.w));

	// --- Optional rim (fresnel, _FresnelWidth)
	color += RimFresnel(N, V) * cel * cParams0.w * light * albedo.rgb * 0.5;

	float alpha = (cParams3.x > 0.5) ? albedo.a : 1.0;
	if (cParams3.x > 0.5) clip(alpha - 0.5);   // cutout, discarded here (GMod doesn't reliably alpha-test)
	return FinishColor(color, alpha, i.worldPosFog.w);
}
