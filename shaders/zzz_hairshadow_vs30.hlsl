// ZZZ hair shadow caster vertex shader (stand-in for the game's NapStencilShadowCaster)
//
// Same skinning/flex path as zzz_body_vs30, then shifts the whole hair by a world-space offset
// computed in Lua from the light and camera (down, away from the light, slightly toward the camera).
// Drawn with colour writes off: it only marks the stencil where the shifted hair lands in front of
// the face, and the face is then redrawn in shadow there.
//
// screenspace_general has no vertex shader constants, so the offset is smuggled through the
// ambient cube (render.SetModelLighting can't be trusted with negative values, so it's split):
//   offset = cAmbientCubeX[0] (BOX_FRONT, positive part) - cAmbientCubeX[1] (BOX_BACK, negative part)

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

VS_OUTPUT main(const VS_INPUT v) {
	float3 vNormal;
	DecompressVertex_Normal(v.vNormal, vNormal);

	float3 vPos = v.vPos.xyz;
	ApplyMorph(v.vPosFlex.xyz, v.vNormalFlex.xyz, vPos, vNormal);

	float3 worldPos, worldNormal;
	SkinPositionAndNormal(true, float4(vPos, 1.0), vNormal, v.vBoneWeights, v.vBoneIndices, worldPos, worldNormal);

	worldPos += cAmbientCubeX[0] - cAmbientCubeX[1];

	float4 projPos = mul(float4(worldPos, 1.0), cViewProj);

	VS_OUTPUT o = (VS_OUTPUT)0;
	o.projPos = projPos;
	o.uv      = v.vTexCoord.xy;
	o.fog     = 1.0;
	return o;
}
