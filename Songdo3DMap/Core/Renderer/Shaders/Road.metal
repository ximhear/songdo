#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

// MARK: - Vertex Input (from vertex descriptor)

struct RoadVertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 texCoord [[attribute(2)]];
};

// MARK: - Road Vertex Output

struct RoadVertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 normal;
    float2 texCoord;
};

// MARK: - Road Vertex Shader

vertex RoadVertexOut road_vertex(
    RoadVertexIn v [[stage_in]],
    constant float4x4& modelMatrix [[buffer(BufferIndexModelMatrix)]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]]
) {
    // Transform position
    float4 worldPos = modelMatrix * float4(v.position, 1.0);

    // Slight elevation above terrain to prevent z-fighting
    worldPos.y += 0.15;

    RoadVertexOut out;
    out.position = uniforms.viewProjectionMatrix * worldPos;
    out.worldPosition = worldPos.xyz;
    out.normal = v.normal;
    out.texCoord = v.texCoord;

    return out;
}

// MARK: - Road Fragment Shader

fragment float4 road_fragment(
    RoadVertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]],
    constant float4& roadColor [[buffer(0)]]
) {
    float3 color = roadColor.rgb;

    // Subtle asphalt texture
    float noise = fract(sin(dot(in.worldPosition.xz, float2(12.9898, 78.233))) * 43758.5453);
    color *= 0.95 + noise * 0.1;

    // Road marking - simple edge darkening
    float edgeFactor = min(in.texCoord.x, 1.0 - in.texCoord.x);
    edgeFactor = smoothstep(0.0, 0.1, edgeFactor);
    color *= 0.8 + edgeFactor * 0.2;

    // Simple lighting
    float3 N = float3(0, 1, 0);
    float3 L = normalize(uniforms.lightDirection);
    float diffuse = max(dot(N, L), 0.0) * 0.3 + 0.7;
    color *= diffuse;

    return float4(color, 1.0);
}

// MARK: - Road Fragment Shader (with markings)

fragment float4 road_fragment_marked(
    RoadVertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]],
    constant float4& roadColor [[buffer(0)]]
) {
    float3 color = roadColor.rgb;

    // Center line (white dashed)
    float lineWidth = 0.04;
    float centerU = abs(in.texCoord.x - 0.5);
    float centerLine = step(centerU, lineWidth);
    float dashPattern = step(0.5, fract(in.texCoord.y * 2.0));

    // Edge lines
    float edgeU = min(in.texCoord.x, 1.0 - in.texCoord.x);
    float edgeLine = step(edgeU, lineWidth * 0.5);

    // Apply road markings
    float3 lineColor = float3(1.0, 1.0, 0.95);
    color = mix(color, lineColor, centerLine * dashPattern * 0.8);
    color = mix(color, lineColor, edgeLine * 0.9);

    // Subtle asphalt texture
    float noise = fract(sin(dot(in.worldPosition.xz, float2(12.9898, 78.233))) * 43758.5453);
    color *= 0.95 + noise * 0.1;

    // Simple lighting
    float3 N = float3(0, 1, 0);
    float3 L = normalize(uniforms.lightDirection);
    float diffuse = max(dot(N, L), 0.0) * 0.3 + 0.7;
    color *= diffuse;

    return float4(color, 1.0);
}

// MARK: - Crosswalk Pattern

float crosswalkPattern(float2 uv, float stripeWidth) {
    float pattern = step(0.5, fract(uv.x / stripeWidth));
    return pattern;
}

// MARK: - Road with Crosswalk

fragment float4 road_crosswalk_fragment(
    RoadVertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]]
) {
    float3 roadColor = float3(0.35, 0.35, 0.38);
    float3 crosswalkColor = float3(0.95, 0.95, 0.9);

    // Crosswalk stripes
    float stripeWidth = 0.1;
    float stripe = crosswalkPattern(in.texCoord, stripeWidth);

    // Only show crosswalk in specific areas (controlled by V coordinate)
    float inCrosswalk = step(0.4, in.texCoord.y) * step(in.texCoord.y, 0.6);

    float3 color = mix(roadColor, crosswalkColor, stripe * inCrosswalk);

    // Lighting
    float diffuse = max(dot(float3(0, 1, 0), normalize(uniforms.lightDirection)), 0.0) * 0.3 + 0.7;
    color *= diffuse;

    return float4(color, 1.0);
}

// MARK: - Sidewalk/Pedestrian Path

fragment float4 sidewalk_fragment(
    RoadVertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]]
) {
    // Brick/tile pattern for sidewalk
    float3 brickColor1 = float3(0.65, 0.6, 0.55);
    float3 brickColor2 = float3(0.7, 0.65, 0.6);

    float brickSize = 0.5;  // meters
    float2 brickUV = in.worldPosition.xz / brickSize;

    // Offset every other row
    brickUV.x += floor(brickUV.y) * 0.5;

    float2 brick = fract(brickUV);
    float2 gap = step(float2(0.05), brick) * step(brick, float2(0.95));
    float isBrick = gap.x * gap.y;

    // Brick variation
    float brickID = floor(brickUV.x) + floor(brickUV.y) * 100.0;
    float variation = fract(sin(brickID * 12.9898) * 43758.5453);

    float3 color = mix(brickColor1, brickColor2, variation);
    color = mix(float3(0.5, 0.48, 0.45), color, isBrick);  // Gap color

    // Lighting
    float diffuse = max(dot(float3(0, 1, 0), normalize(uniforms.lightDirection)), 0.0) * 0.3 + 0.7;
    color *= diffuse;

    return float4(color, 1.0);
}
