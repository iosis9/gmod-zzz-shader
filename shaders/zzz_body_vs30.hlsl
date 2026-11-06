// ZZZ NPR body vertex shader (screenspace_general_8tex, $model 1)
//
// Mirrors the input layout that ExoPBR proved works in GMod's screenspace_general:
// hardware skinning (3 bones), UBYTE4-compressed normal+tangent, and flex deltas
// from a second stream. No $softwareskin needed.

#define COMPRESSED_VERTS 1
#include "common_vs_fxc.h"

struct VS_INPUT {
	float4 vPos          : POSITION;
	float4 vBoneWeights  : BLENDWEIGHT;
	float4 vBoneIndices  : BLENDINDICES;
	float4 vNormal       : NORMAL;     // compressed normal + tangent (UBYTE4)
	float4 vTexCoord     : TEXCOORD0;
	float4 vPosFlex      : POSITION1;  // flex position delta
	float4 vNormalFlex   : NORMAL1;    // flex normal delta
};

struct VS_OUTPUT {
	float4 projPos       : POSITION;
	float2 uv            : TEXCOORD0;
	float3 worldNormal   : TEXCOORD1;
	float4 worldTangent  : TEXCOORD2;  // xyz tangent, w bitangent sign
	float4 worldPosFog   : TEXCOORD3;  // xyz world position, w fog visibility (1 = no fog)
	float4 lightAtten    : TEXCOORD4;  // attenuation of the 4 engine lights
};

VS_OUTPUT main(const VS_INPUT v) {
	float3 vNormal;
	float4 vTangent;
	DecompressVertex_NormalTangent(v.vNormal, v.vNormal, vNormal, vTangent);

	float3 vPos = v.vPos.xyz;
	float3 vTan = vTangent.xyz;
	ApplyMorph(v.vPosFlex.xyz, v.vNormalFlex.xyz, vPos, vNormal, vTan);

	float3 worldPos, worldNormal, worldTangentS, worldTangentT;
	SkinPositionNormalAndTangentSpace(true, float4(vPos, 1.0), vNormal, float4(vTan, vTangent.w),
		v.vBoneWeights, v.vBoneIndices, worldPos, worldNormal, worldTangentS, worldTangentT);

	float4 projPos = mul(float4(worldPos, 1.0), cViewProj);

	VS_OUTPUT o = (VS_OUTPUT)0;
	o.projPos      = projPos;
	o.uv           = v.vTexCoord.xy;
	o.worldNormal  = normalize(worldNormal);
	o.worldTangent = float4(normalize(worldTangentS), vTangent.w);
	o.worldPosFog  = float4(worldPos, saturate(CalcFog(worldPos, projPos.xyz, FOGTYPE_RANGE)));

	// Disabled lights have zero colour on the pixel side, so computing all 4 is safe
	o.lightAtten.x = GetVertexAttenForLight(worldPos, 0, false);
	o.lightAtten.y = GetVertexAttenForLight(worldPos, 1, false);
	o.lightAtten.z = GetVertexAttenForLight(worldPos, 2, false);
	o.lightAtten.w = GetVertexAttenForLight(worldPos, 3, false);
	return o;
}
