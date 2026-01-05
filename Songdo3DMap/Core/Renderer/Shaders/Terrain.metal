#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

// MARK: - Terrain Vertex Output

struct TerrainVertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 worldNormal;
    float2 texCoord;
    float height;
};

// MARK: - Terrain Vertex Shader (Heightmap-based)

vertex TerrainVertexOut terrain_vertex(
    uint vertexID [[vertex_id]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]],
    constant TerrainUniforms& terrainUniforms [[buffer(2)]],
    texture2d<float> heightmap [[texture(TextureIndexHeightmap)]]
) {
    // Calculate grid position from vertex ID
    uint gridWidth = terrainUniforms.gridWidth;
    uint gridHeight = terrainUniforms.gridHeight;

    uint gridX = vertexID % gridWidth;
    uint gridY = vertexID / gridWidth;

    // Normalized UV coordinates
    float2 uv = float2(float(gridX) / float(gridWidth - 1),
                       float(gridY) / float(gridHeight - 1));

    // Sample height from heightmap
    constexpr sampler heightSampler(filter::linear, address::clamp_to_edge);
    float height = heightmap.sample(heightSampler, uv).r * terrainUniforms.heightScale;

    // Calculate world position
    float3 worldPos = float3(
        terrainUniforms.terrainOrigin.x + uv.x * terrainUniforms.terrainSize.x,
        height,
        terrainUniforms.terrainOrigin.y + uv.y * terrainUniforms.terrainSize.y
    );

    // Calculate normal using central differences
    float texelSize = 1.0 / float(gridWidth);
    float hL = heightmap.sample(heightSampler, uv + float2(-texelSize, 0)).r * terrainUniforms.heightScale;
    float hR = heightmap.sample(heightSampler, uv + float2(texelSize, 0)).r * terrainUniforms.heightScale;
    float hU = heightmap.sample(heightSampler, uv + float2(0, -texelSize)).r * terrainUniforms.heightScale;
    float hD = heightmap.sample(heightSampler, uv + float2(0, texelSize)).r * terrainUniforms.heightScale;

    float3 normal = normalize(float3(hL - hR, 2.0, hU - hD));

    TerrainVertexOut out;
    out.position = uniforms.viewProjectionMatrix * float4(worldPos, 1.0);
    out.worldPosition = worldPos;
    out.worldNormal = normal;
    out.texCoord = uv * terrainUniforms.textureTiling;
    out.height = height;

    return out;
}

// MARK: - Terrain Fragment Shader

fragment float4 terrain_fragment(
    TerrainVertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]],
    texture2d<float> grassTexture [[texture(0)]],
    texture2d<float> rockTexture [[texture(1)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 L = normalize(uniforms.lightDirection);
    float3 V = normalize(uniforms.cameraPosition - in.worldPosition);

    constexpr sampler texSampler(filter::linear, address::repeat, mip_filter::linear);

    // Sample textures
    float3 grassColor = grassTexture.sample(texSampler, in.texCoord).rgb;
    float3 rockColor = rockTexture.sample(texSampler, in.texCoord).rgb;

    // Blend based on slope (steeper = more rock)
    float slope = 1.0 - N.y;
    float rockBlend = smoothstep(0.3, 0.7, slope);
    float3 albedo = mix(grassColor, rockColor, rockBlend);

    // Height-based color variation
    float heightBlend = smoothstep(0.0, 50.0, in.height);
    albedo = mix(albedo, albedo * 0.9, heightBlend);

    // Lighting
    float ambient = 0.3;
    float diffuse = max(dot(N, L), 0.0);

    // Soft shadows based on height
    float shadow = 1.0;

    float3 color = albedo * (ambient + diffuse * shadow * 0.7);

    // Distance fog
    float distance = length(uniforms.cameraPosition - in.worldPosition);
    float fogFactor = 1.0 - exp(-distance * 0.0002);
    float3 fogColor = float3(0.529, 0.808, 0.922); // Sky color
    color = mix(color, fogColor, fogFactor);

    return float4(color, 1.0);
}

// MARK: - Simple Terrain Fragment (No Textures)

fragment float4 terrain_fragment_simple(
    TerrainVertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 L = normalize(uniforms.lightDirection);

    // Base ground color (greenish gray for Songdo)
    float3 baseColor = float3(0.55, 0.6, 0.5);

    // Height-based color (송도는 매립지라 거의 평탄)
    float heightFactor = saturate(in.height / 10.0);
    float3 albedo = mix(baseColor, baseColor * 1.1, heightFactor);

    // Lighting
    float ambient = 0.35;
    float diffuse = max(dot(N, L), 0.0);
    float3 color = albedo * (ambient + diffuse * 0.65);

    // Grid overlay for reference
    float gridScale = 100.0;
    float2 gridCoord = in.worldPosition.xz / gridScale;
    float2 grid = abs(fract(gridCoord - 0.5) - 0.5) / fwidth(gridCoord);
    float gridLine = 1.0 - min(min(grid.x, grid.y), 1.0);
    color = mix(color, color * 0.8, gridLine * 0.3);

    return float4(color, 1.0);
}

// MARK: - Flat Terrain for Songdo (Reclaimed Land)

vertex TerrainVertexOut terrain_flat_vertex(
    uint vertexID [[vertex_id]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]],
    constant TerrainUniforms& terrainUniforms [[buffer(2)]]
) {
    // Generate a flat grid (송도는 매립지로 거의 평탄)
    uint gridWidth = terrainUniforms.gridWidth;

    uint gridX = vertexID % gridWidth;
    uint gridY = vertexID / gridWidth;

    float2 uv = float2(float(gridX) / float(gridWidth - 1),
                       float(gridY) / float(gridWidth - 1));

    float3 worldPos = float3(
        terrainUniforms.terrainOrigin.x + uv.x * terrainUniforms.terrainSize.x,
        0.0,  // Flat terrain
        terrainUniforms.terrainOrigin.y + uv.y * terrainUniforms.terrainSize.y
    );

    TerrainVertexOut out;
    out.position = uniforms.viewProjectionMatrix * float4(worldPos, 1.0);
    out.worldPosition = worldPos;
    out.worldNormal = float3(0, 1, 0);
    out.texCoord = uv * terrainUniforms.textureTiling;
    out.height = 0;

    return out;
}

fragment float4 terrain_flat_fragment(
    TerrainVertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]]
) {
    float3 N = float3(0, 1, 0);
    float3 L = normalize(uniforms.lightDirection);

    // Songdo land color palette
    float3 landColor = float3(0.75, 0.78, 0.72);  // Light gray-green
    float3 parkColor = float3(0.45, 0.55, 0.35);  // Green for parks

    // Create subtle zones based on position
    float noise = fract(sin(dot(floor(in.worldPosition.xz / 200.0), float2(12.9898, 78.233))) * 43758.5453);
    float isPark = step(0.8, noise);
    float3 albedo = mix(landColor, parkColor, isPark);

    // Lighting
    float diffuse = max(dot(N, L), 0.0) * 0.5 + 0.5;
    float3 color = albedo * diffuse;

    // Block grid (50m blocks typical for urban areas)
    float blockSize = 50.0;
    float2 blockCoord = in.worldPosition.xz / blockSize;
    float2 blockGrid = abs(fract(blockCoord - 0.5) - 0.5) / fwidth(blockCoord);
    float blockLine = 1.0 - min(min(blockGrid.x, blockGrid.y), 1.0);
    color = mix(color, float3(0.6, 0.62, 0.58), blockLine * 0.2);

    // Distance fade
    float distance = length(in.worldPosition.xz - uniforms.cameraPosition.xz);
    float fade = 1.0 - smoothstep(3000.0, 5000.0, distance);
    color = mix(float3(0.529, 0.808, 0.922), color, fade);

    return float4(color, 1.0);
}
