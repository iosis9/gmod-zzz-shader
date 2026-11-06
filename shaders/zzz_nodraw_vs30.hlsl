// Draws nothing: every vertex is placed outside the clip volume, so all triangles are clipped.
// Used by zzz_outline_skip to hide submaterials in the outline and hair shadow passes. (Returning
// alpha 0 from the pixel shader is NOT enough: the alpha test doesn't reliably discard it.)

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
	VS_OUTPUT o = (VS_OUTPUT)0;
	o.projPos = float4(2.0, 2.0, 2.0, 1.0);   // x, y > w: outside the frustum
	o.uv      = v.vTexCoord.xy;
	o.fog     = 1.0;
	return o;
}
