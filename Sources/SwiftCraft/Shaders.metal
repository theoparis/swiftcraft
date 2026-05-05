#include <metal_stdlib>
using namespace metal;

struct TerrainVertexIn {
    float3 position [[attribute(0)]];
    float2 uv [[attribute(1)]];
    float3 color [[attribute(2)]];
    float shade [[attribute(3)]];
};

struct FrameUniforms {
    float4x4 viewProjectionMatrix;
    float3 cameraPosition;
    float underwater;
};

struct TerrainRasterizerData {
    float4 position [[position]];
    float3 worldPosition;
    float2 uv;
    float3 color;
    float shade;
};

vertex TerrainRasterizerData terrainVertex(
    TerrainVertexIn in [[stage_in]],
    constant FrameUniforms& uniforms [[buffer(1)]]
) {
    TerrainRasterizerData out;
    out.position = uniforms.viewProjectionMatrix * float4(in.position, 1.0);
    out.worldPosition = in.position;
    out.uv = in.uv;
    out.color = in.color;
    out.shade = in.shade;
    return out;
}

fragment float4 terrainFragment(
    TerrainRasterizerData in [[stage_in]],
    constant FrameUniforms& uniforms [[buffer(1)]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    float4 albedo = atlas.sample(atlasSampler, in.uv);
    float3 color = albedo.rgb * in.color * in.shade;
    if (uniforms.underwater > 0.5) {
        float distanceToCamera = distance(in.worldPosition, uniforms.cameraPosition);
        float fog = clamp(distanceToCamera / 24.0, 0.0, 1.0);
        color = mix(color, float3(0.02, 0.22, 0.30), fog);
    }
    return float4(color, 1.0);
}

fragment float4 waterFragment(
    TerrainRasterizerData in [[stage_in]],
    constant FrameUniforms& uniforms [[buffer(1)]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    float4 albedo = atlas.sample(atlasSampler, in.uv);
    // Beta 1.8.1 water: muted deep blue, mostly solid colour with subtle texture detail.
    float3 baseBlue = float3(0.24, 0.46, 0.94);
    float3 tinted = mix(albedo.rgb * float3(0.4, 0.6, 1.1), baseBlue, 0.65) * in.shade;
    float alpha = 0.80;
    if (uniforms.underwater > 0.5) {
        float distanceToCamera = distance(in.worldPosition, uniforms.cameraPosition);
        float fog = clamp(distanceToCamera / 20.0, 0.0, 1.0);
        tinted = mix(tinted, float3(0.03, 0.18, 0.38), fog);
        alpha = 0.40;
    }
    return float4(tinted, alpha);
}
