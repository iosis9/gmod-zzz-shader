// ZZZ face, hair-shadow pass: the face shader with everything forced into the shadow band.
// Drawn by Lua only where the shifted hair marked the stencil, alpha-blended by the hair shadow
// strength (passed in c17.w, the render-blend slot).
#define ZZZ_HAIR_SHADOW 1
#include "zzz_face_ps30.hlsl"
