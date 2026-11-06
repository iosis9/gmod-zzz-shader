// ZZZ inverted-hull outline vertex shader
//
// Same skinning/flex path as zzz_body_vs30, then pushes the vertex out along its normal.
// Drawn by the Lua RenderOverride with front-face culling, so only the shell behind the model shows.
//
// screenspace_general has no vertex shader constants, so the width is smuggled through the
// ambient cube (render.SetModelLighting, same trick as gmod_shader_guide example 6):
//   cAmbientCubeX[0] = (width, 0.5, 0.25)   the .yz pair is a signature; without it defaults are used
//   cAmbientCubeX[1] = (max distance, fov scale, min on-screen scale 0..1)
//       fov scale = tan(fov/2) / tan(75/2): zooming in (smaller fov) shrinks it, so distance is
//       measured as "apparent" distance. Past max distance the outline stops growing in world
//       units and shrinks on screen with the model.

#define COMPRESSED_VERTS 1
#include "common_vs_fxc.h"

struct VS_INPUT {
	float4 vPos          : POSITION;
	float4 vBoneWeights  : BLENDWEIGHT;
	float4 vBoneIndices  : BLENDINDICES;
	float4 vNormal       : NORMAL;
	float4 vTexCoord     : TEXCOORD0;
	float4 vPosFlex      : POSITION1;
	float4 vNormalFlex   : NORMAL1;
};

struct VS_OUTPUT {
	float4 projPos     : POSITION;
	float2 uv          : TEXCOORD0;
	float  fog         : TEXCOORD1;
};

static const float DEFAULT_WIDTH = 1.0;
static const float DEFAULT_MAX_DISTANCE = 100.0;
static const float DEFAULT_MIN_SCALE = 0.5;
static const float WIDTH_PER_UNIT_DISTANCE = 0.0009; // world-space push per unit of camera distance at width 1

VS_OUTPUT main(const VS_INPUT v) {
	float3 vNormal;
	DecompressVertex_Normal(v.vNormal, vNormal);

	float3 vPos = v.vPos.xyz;
	ApplyMorph(v.vPosFlex.xyz, v.vNormalFlex.xyz, vPos, vNormal);

	float3 worldPos, worldNormal;
	SkinPositionAndNormal(true, float4(vPos, 1.0), vNormal, v.vBoneWeights, v.vBoneIndices, worldPos, worldNormal);
	worldNormal = normalize(worldNormal);

	float3 meta = cAmbientCubeX[0];
	bool hasMeta = abs(meta.y - 0.5) < 0.01 && abs(meta.z - 0.25) < 0.01;
	float width   = hasMeta ? meta.x : DEFAULT_WIDTH;
	float maxDist  = hasMeta ? max(cAmbientCubeX[1].x, 1.0) : DEFAULT_MAX_DISTANCE;
	float fovScale = hasMeta ? max(cAmbientCubeX[1].y, 0.001) : 1.0;
	float minScale = hasMeta ? saturate(cAmbientCubeX[1].z) : DEFAULT_MIN_SCALE;

	// Constant on-screen thickness up close (accounting for zoom); past maxDist the push is frozen
	// in world units, so the outline shrinks along with the model instead of swallowing it - but
	// never below minScale of its close-up on-screen thickness
	float apparentDist = length(cEyePos - worldPos) * fovScale;
	float dist = max(min(apparentDist, maxDist), apparentDist * minScale);
	worldPos += worldNormal * (width * WIDTH_PER_UNIT_DISTANCE * dist);

	float4 projPos = mul(float4(worldPos, 1.0), cViewProj);

	VS_OUTPUT o = (VS_OUTPUT)0;
	o.projPos = projPos;
	o.uv      = v.vTexCoord.xy;
	o.fog     = saturate(CalcFog(worldPos, projPos.xyz, FOGTYPE_RANGE));
	return o;
}
