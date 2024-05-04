//
//  Shaders.metal
//  MetalDeferred
//
//

#include <metal_stdlib>

using namespace metal;

#define SRGB_ALPHA 0.055

float linear_from_srgb(float x)
{
    // rgb = mix(rgb*0.0774, pow(rgb*0.9479 + 0.05213, 2.4), step(0.04045,rgb))
    if (x <= 0.04045)
        return x / 12.92;
    else
        return powr((x + SRGB_ALPHA) / (1.0 + SRGB_ALPHA), 2.4);
}

float3 linear_from_srgb(float3 rgb)
{
    return float3(linear_from_srgb(rgb.r),
                  linear_from_srgb(rgb.g),
                  linear_from_srgb(rgb.b));
}

float srgb_from_linear(float c) {
    // rgb = mix(rgb*12.92, pow(rgb,0.4167) * 1.055 - 0.055, step(0.00313,rgb))
    if (isnan(c))
        c = 0.0;
    if (c > 1.0)
        c = 1.0;
    else if (c < 0.0)
        c = 0.0;
    else if (c < 0.0031308)
        c = 12.92 * c;
    else
        //c = 1.055 * powr(c, 1.0/2.4) - 0.055;
        c = (1.0 + SRGB_ALPHA) * powr(c, 1.0/2.4) - SRGB_ALPHA;
    
    return c;
}

float3 srgb_from_linear(float3 rgb)
{
    return float3(srgb_from_linear(rgb.r),
                  srgb_from_linear(rgb.g),
                  srgb_from_linear(rgb.b));
}
typedef struct {
    float4 clip_pos [[position]];
    float2 uv;
} ScreenFragment;

vertex ScreenFragment
screen_vert(uint vid [[vertex_id]])
{
    // from "Vertex Shader Tricks" by AMD - GDC 2014
    ScreenFragment out;
    out.clip_pos = float4((float)(vid / 2) * 4.0 - 1.0,
                          (float)(vid % 2) * 4.0 - 1.0,
                          0.0,
                          1.0);
    out.uv = float2((float)(vid / 2) * 2.0,
                    1.0 - (float)(vid % 2) * 2.0);
    return out;
}

/*
 The range of uv: [0.0, 1.0]
 The origin of the Metal texture coord system is at the upper-left of the quad.
 */
fragment half4
screen_frag(ScreenFragment  in  [[stage_in]],
            texture2d<half> tex [[texture(0)]]) {

    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);

    half4 out_color = tex.sample(textureSampler, in.uv);
    //float3 final_colour = linear_from_srgb(float3(out_color.xyz));
    //return half4(half3(final_colour), 1.0);//
    return out_color;

}

/////// Kernel function code
// BT.601, which is the standard for SDTV.
constant float3x3 kColorConversion601 = float3x3(
    float3(1.164,  1.164, 1.164),
    float3(0.000, -0.392, 2.017),
    float3(1.596, -0.813, 0.000));

// BT.709, which is the standard for HDTV.
constant float3x3 kColorConversion709 = float3x3(
    float3(1.164,  1.164, 1.164),
    float3(0.000, -0.213, 2.112),
    float3(1.793, -0.533, 0.000));

constant float3 colorOffset = float3(-(16.0/255.0), -0.5, -0.5);

kernel void
YCbCrColorConversion(texture2d<float, access::read>   yTexture  [[texture(0)]],
                     texture2d<float, access::read> cbcrTexture [[texture(1)]],
                     texture2d<float, access::write> outTexture [[texture(2)]],
                     uint2                              gid     [[thread_position_in_grid]])
{
    uint width = outTexture.get_width();
    uint height = outTexture.get_height();
    uint column = gid.x;
    uint row = gid.y;
    if ((column >= width) || (row >= height)) {
        // In case the size of the texture does not match the size of the grid.
        // Return early if the pixel is out of bounds
        return;
    }

    uint2 cbcrCoordinates = uint2(column / 2, row / 2);

    float y = yTexture.read(gid).r;
    float2 cbcr = cbcrTexture.read(cbcrCoordinates).rg;

    float3 ycbcr = float3(y, cbcr);

    float3 rgb = kColorConversion709 * (ycbcr + colorOffset);

    outTexture.write(float4(float3(rgb), 1.0), gid);
}
