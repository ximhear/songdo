#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

// MARK: - Common Vertex Outputs

struct VertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 worldNormal;
    float2 texCoord;
    float4 color;
};

// MARK: - Utility Functions

// Compute view direction
inline float3 computeViewDirection(float3 worldPos, float3 cameraPos) {
    return normalize(cameraPos - worldPos);
}

// Basic Phong lighting
inline float3 computePhongLighting(
    float3 normal,
    float3 lightDir,
    float3 viewDir,
    float3 albedo,
    float3 lightColor,
    float3 ambientColor,
    float shininess = 32.0
) {
    // Ambient
    float3 ambient = ambientColor * albedo;

    // Diffuse
    float NdotL = max(dot(normal, lightDir), 0.0);
    float3 diffuse = NdotL * lightColor * albedo;

    // Specular (Blinn-Phong)
    float3 halfDir = normalize(lightDir + viewDir);
    float NdotH = max(dot(normal, halfDir), 0.0);
    float spec = pow(NdotH, shininess);
    float3 specular = spec * lightColor * 0.3;

    return ambient + diffuse + specular;
}

// Fresnel effect for glass buildings
inline float computeFresnel(float3 normal, float3 viewDir, float power = 2.0) {
    float NdotV = max(dot(normal, viewDir), 0.0);
    return pow(1.0 - NdotV, power);
}

// Height-based fog
inline float3 applyFog(float3 color, float3 fogColor, float distance, float height, float density = 0.001) {
    float fogFactor = 1.0 - exp(-distance * density);
    fogFactor *= saturate(1.0 - height / 500.0); // Reduce fog at higher altitudes
    return mix(color, fogColor, fogFactor);
}

// MARK: - Matrix Utilities

inline float4x4 makeTranslation(float3 translation) {
    return float4x4(
        float4(1, 0, 0, 0),
        float4(0, 1, 0, 0),
        float4(0, 0, 1, 0),
        float4(translation, 1)
    );
}

inline float4x4 makeScale(float3 scale) {
    return float4x4(
        float4(scale.x, 0, 0, 0),
        float4(0, scale.y, 0, 0),
        float4(0, 0, scale.z, 0),
        float4(0, 0, 0, 1)
    );
}

inline float4x4 makeRotationY(float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return float4x4(
        float4(c, 0, s, 0),
        float4(0, 1, 0, 0),
        float4(-s, 0, c, 0),
        float4(0, 0, 0, 1)
    );
}

// MARK: - Frustum Culling (GPU-side)

inline bool isInsideFrustum(float3 position, float radius, constant FrustumPlanes& frustum) {
    for (int i = 0; i < 6; i++) {
        float4 plane = frustum.planes[i];
        float distance = dot(plane.xyz, position) + plane.w;
        if (distance < -radius) {
            return false;
        }
    }
    return true;
}

// MARK: - LOD Selection (GPU-side)

inline uint selectLOD(float distance, float objectSize) {
    float screenSize = objectSize / distance * 1000.0; // Approximate screen size

    if (screenSize > 80.0) return 0;  // Full detail
    if (screenSize > 30.0) return 1;  // Medium
    if (screenSize > 10.0) return 2;  // Low
    return 3;  // Culled or impostor
}

// MARK: - Simple Test Shader

vertex VertexOut simple_vertex(
    uint vertexID [[vertex_id]],
    constant Vertex* vertices [[buffer(BufferIndexVertices)]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]]
) {
    Vertex v = vertices[vertexID];

    VertexOut out;
    float4 worldPos = float4(v.position, 1.0);
    out.position = uniforms.viewProjectionMatrix * worldPos;
    out.worldPosition = worldPos.xyz;
    out.worldNormal = v.normal;
    out.texCoord = v.texCoord;
    out.color = float4(1.0);

    return out;
}

fragment float4 simple_fragment(
    VertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 L = normalize(uniforms.lightDirection);
    float3 V = computeViewDirection(in.worldPosition, uniforms.cameraPosition);

    float3 albedo = float3(0.7, 0.75, 0.8);
    float3 color = computePhongLighting(N, L, V, albedo, uniforms.lightColor, uniforms.ambientColor);

    return float4(color, 1.0);
}

// MARK: - Grid Shader (for ground plane visualization)

vertex VertexOut grid_vertex(
    uint vertexID [[vertex_id]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]]
) {
    // Generate a large ground plane grid
    const float gridSize = 10000.0;
    const float halfSize = gridSize / 2.0;

    // 4 vertices for a quad
    float2 positions[4] = {
        float2(-halfSize, -halfSize),
        float2( halfSize, -halfSize),
        float2(-halfSize,  halfSize),
        float2( halfSize,  halfSize)
    };

    uint indices[6] = { 0, 1, 2, 1, 3, 2 };
    uint idx = indices[vertexID % 6];
    float2 pos = positions[idx];

    VertexOut out;
    float4 worldPos = float4(pos.x, 0.0, pos.y, 1.0);
    out.position = uniforms.viewProjectionMatrix * worldPos;
    out.worldPosition = worldPos.xyz;
    out.worldNormal = float3(0, 1, 0);
    out.texCoord = (pos / gridSize) + 0.5;
    out.color = float4(1.0);

    return out;
}

fragment float4 grid_fragment(
    VertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]]
) {
    // Grid pattern
    float gridScale = 100.0;
    float2 coord = in.worldPosition.xz / gridScale;
    float2 grid = abs(fract(coord - 0.5) - 0.5) / fwidth(coord);
    float line = min(grid.x, grid.y);
    float gridAlpha = 1.0 - min(line, 1.0);

    // Base color (light gray ground)
    float3 groundColor = float3(0.85, 0.87, 0.85);
    float3 lineColor = float3(0.6, 0.65, 0.6);

    // Major grid lines (every 500m)
    float majorScale = 500.0;
    float2 majorCoord = in.worldPosition.xz / majorScale;
    float2 majorGrid = abs(fract(majorCoord - 0.5) - 0.5) / fwidth(majorCoord);
    float majorLine = min(majorGrid.x, majorGrid.y);
    float majorAlpha = 1.0 - min(majorLine, 1.0);

    float3 color = mix(groundColor, lineColor, gridAlpha * 0.3);
    color = mix(color, float3(0.4, 0.45, 0.4), majorAlpha * 0.5);

    // Distance fade
    float distance = length(in.worldPosition.xz);
    float fade = saturate(1.0 - distance / 5000.0);
    color = mix(float3(0.529, 0.808, 0.922), color, fade); // Fade to sky color

    return float4(color, 1.0);
}
