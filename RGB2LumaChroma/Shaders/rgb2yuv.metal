
// https://stackoverflow.com/questions/33339874/rgb-to-yuv-using-shader - OpenGL shader.
#include <metal_stdlib>

using namespace metal;

typedef struct {
     float3x3 matrix;
     float3   offset;   // 16.0/255.0, 128.0/255.0, 128.0/255.0
} ColorConversion;

// ITU-R BT.709 (HDTV)
constant float3x3 colorConversion = float3x3(
    float3(0.183, -0.101,  0.439),  // column 0
    float3(0.614, -0.339, -0.339),
    float3(0.062,  0.439, -0.040)
);

constant float3 colorConversionOffsets = float3(+0.0063, +0.5000, +0.5000);
/*
constant float4x4 rgbaToYcbcrTransform = float4x4(
   float4(+0.2990, -0.1687, +0.5000, +0.0000),
   float4(+0.5870, -0.3313, -0.4187, +0.0000),
   float4(+0.1140, +0.5000, -0.0813, +0.0000),
   float4(+0.0000, +0.5000, +0.5000, +1.0000)
);
*/
// Compute kernel - assume normalised colors in the textures.
// Shader colors are always linear
kernel void
rgb2ycbcrColorConversion(texture2d<half, access::sample> inputTexture [[ texture(0) ]],
                         texture2d<half, access::write> textureY      [[ texture(1) ]],
                         texture2d<half, access::write> textureCbCr   [[ texture(2) ]],
                         uint2                              gid       [[thread_position_in_grid]])
{
    // Make sure we don't read or write outside of the texture
    if ((gid.x >= inputTexture.get_width()) || (gid.y >= inputTexture.get_height())) {
        return;
    }

    float3 inputColor = float3(inputTexture.read(gid).rgb);

    float3 yuv = colorConversion*inputColor + colorConversionOffsets;

    // g - Cb, b - Cr
    half2 uv = half2(yuv.gb);

    textureY.write(half4(yuv.x), gid);

    if (gid.x % 2 == 0 && gid.y % 2 == 0) {
        // r - Cb, g - Cr, b - 0, a - 1.0
        textureCbCr.write(half4(half2(uv), 0.0, 1.0),
                          uint2(gid.x / 2, gid.y / 2));
    }
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
    return out_color;
}

