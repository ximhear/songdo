#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

// MARK: - Function Constants
constant bool hasTexture [[function_constant(0)]];

// MARK: - Vertex Input (from vertex descriptor)

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 texCoord [[attribute(2)]];
};

// MARK: - Building Vertex Output

struct BuildingVertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 worldNormal;
    float2 texCoord;
    float4 color;
    uint textureIndex;
};

// MARK: - Building Vertex Shader (Per-object model matrix)

vertex BuildingVertexOut building_vertex(
    VertexIn vert [[stage_in]],
    constant float4x4& modelMatrix [[buffer(BufferIndexModelMatrix)]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]]
) {
    // Transform vertex by model matrix
    float4 worldPos = modelMatrix * float4(vert.position, 1.0);

    // Transform normal (assuming uniform scale)
    float3x3 normalMatrix = float3x3(
        modelMatrix[0].xyz,
        modelMatrix[1].xyz,
        modelMatrix[2].xyz
    );
    float3 worldNormal = normalize(normalMatrix * vert.normal);

    BuildingVertexOut out;
    out.position = uniforms.viewProjectionMatrix * worldPos;
    out.worldPosition = worldPos.xyz;
    out.worldNormal = worldNormal;
    out.texCoord = vert.texCoord;
    out.color = float4(1.0);  // Will be set by fragment shader
    out.textureIndex = 0;

    return out;
}

// MARK: - Building Vertex Shader (Instanced) - for batch rendering

vertex BuildingVertexOut building_vertex_instanced(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant Vertex* vertices [[buffer(BufferIndexVertices)]],
    constant BuildingInstance* instances [[buffer(BufferIndexInstances)]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]]
) {
    Vertex vert = vertices[vertexID];
    BuildingInstance instance = instances[instanceID];

    // Transform vertex by instance model matrix
    float4 worldPos = instance.modelMatrix * float4(vert.position, 1.0);

    // Transform normal (assuming uniform scale)
    float3x3 normalMatrix = float3x3(
        instance.modelMatrix[0].xyz,
        instance.modelMatrix[1].xyz,
        instance.modelMatrix[2].xyz
    );
    float3 worldNormal = normalize(normalMatrix * vert.normal);

    BuildingVertexOut out;
    out.position = uniforms.viewProjectionMatrix * worldPos;
    out.worldPosition = worldPos.xyz;
    out.worldNormal = worldNormal;
    out.texCoord = vert.texCoord;
    out.color = instance.color;
    out.textureIndex = instance.textureIndex;

    return out;
}

// MARK: - Building Fragment Shader

fragment float4 building_fragment(
    BuildingVertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]],
    constant float4& objectColor [[buffer(0)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 L = normalize(uniforms.lightDirection);
    float3 V = normalize(uniforms.cameraPosition - in.worldPosition);

    // Base color from uniform
    float3 albedo = objectColor.rgb;

    // Building color based on height (subtle variation)
    float heightFactor = saturate(in.worldPosition.y / 50.0);
    albedo = mix(albedo * 0.9, albedo * 1.1, heightFactor);

    // Lighting calculation
    // Ambient
    float3 ambient = uniforms.ambientColor * albedo * 0.3;

    // Diffuse
    float NdotL = max(dot(N, L), 0.0);
    float3 diffuse = NdotL * uniforms.lightColor * albedo;

    // Specular (Blinn-Phong)
    float3 H = normalize(L + V);
    float NdotH = max(dot(N, H), 0.0);
    float spec = pow(NdotH, 32.0);
    float3 specular = spec * uniforms.lightColor * 0.2;

    // Rim lighting for depth
    float rim = 1.0 - max(dot(N, V), 0.0);
    rim = pow(rim, 3.0);
    float3 rimColor = rim * float3(0.3, 0.35, 0.4) * 0.3;

    float3 finalColor = ambient + diffuse + specular + rimColor;

    return float4(finalColor, objectColor.a);
}

// MARK: - Building Fragment Shader (with texture)

fragment float4 building_fragment_textured(
    BuildingVertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]],
    constant float4& objectColor [[buffer(0)]],
    texture2d<float> wallTexture [[texture(TextureIndexColor)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 L = normalize(uniforms.lightDirection);
    float3 V = normalize(uniforms.cameraPosition - in.worldPosition);

    // Sample texture
    constexpr sampler texSampler(filter::linear, address::repeat);
    float4 texColor = wallTexture.sample(texSampler, in.texCoord);
    float3 albedo = objectColor.rgb * texColor.rgb;

    // Lighting calculation
    float3 ambient = uniforms.ambientColor * albedo * 0.3;
    float NdotL = max(dot(N, L), 0.0);
    float3 diffuse = NdotL * uniforms.lightColor * albedo;

    float3 H = normalize(L + V);
    float NdotH = max(dot(N, H), 0.0);
    float spec = pow(NdotH, 32.0);
    float3 specular = spec * uniforms.lightColor * 0.2;

    float3 finalColor = ambient + diffuse + specular;

    return float4(finalColor, objectColor.a * texColor.a);
}

// MARK: - Building Fragment Shader (No Texture)

fragment float4 building_fragment_simple(
    BuildingVertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 L = normalize(uniforms.lightDirection);
    float3 V = normalize(uniforms.cameraPosition - in.worldPosition);

    float3 albedo = in.color.rgb;

    // Simple lighting
    float ambient = 0.3;
    float diffuse = max(dot(N, L), 0.0);

    // Height-based color variation
    float heightFactor = saturate(in.worldPosition.y / 100.0);
    albedo = mix(albedo, albedo * 1.1, heightFactor);

    float3 color = albedo * (ambient + diffuse * 0.7);

    // Fresnel edge highlight
    float fresnel = pow(1.0 - max(dot(N, V), 0.0), 2.0);
    color += fresnel * 0.1;

    return float4(color, 1.0);
}

// MARK: - Glass Building Fragment Shader

fragment float4 building_glass_fragment(
    BuildingVertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 V = normalize(uniforms.cameraPosition - in.worldPosition);
    float3 L = normalize(uniforms.lightDirection);

    // Fresnel effect for glass
    float fresnel = pow(1.0 - max(dot(N, V), 0.0), 3.0);

    // Glass base color (bluish tint)
    float3 glassColor = float3(0.4, 0.5, 0.6);

    // Reflection simulation
    float3 R = reflect(-V, N);
    float skyReflection = max(R.y, 0.0);
    float3 reflectionColor = mix(float3(0.6, 0.7, 0.8), float3(0.9, 0.95, 1.0), skyReflection);

    // Specular highlight
    float3 H = normalize(L + V);
    float spec = pow(max(dot(N, H), 0.0), 64.0);

    // Combine
    float3 color = mix(glassColor, reflectionColor, fresnel * 0.6);
    color += spec * 0.3;

    // Glass transparency
    float alpha = mix(0.4, 0.9, fresnel);

    return float4(color, alpha);
}

// MARK: - Window Shader (for building facades)

fragment float4 window_fragment(
    BuildingVertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 V = normalize(uniforms.cameraPosition - in.worldPosition);

    // Window grid pattern
    float2 uv = in.texCoord;
    float windowWidth = 0.2;
    float windowHeight = 0.15;

    float2 grid = fract(uv / float2(windowWidth, windowHeight));
    float2 border = step(float2(0.1), grid) * step(grid, float2(0.9));
    float isWindow = border.x * border.y;

    // Wall color
    float3 wallColor = in.color.rgb;

    // Window color (with slight randomization for lit/unlit windows)
    float windowSeed = floor(uv.x / windowWidth) + floor(uv.y / windowHeight) * 100.0;
    float isLit = step(0.6, fract(sin(windowSeed * 12.9898) * 43758.5453));

    float3 windowColor = isLit ?
        float3(1.0, 0.95, 0.8) * 0.8 :  // Warm lit window
        float3(0.2, 0.25, 0.35);         // Dark window

    // Fresnel for glass effect on windows
    float fresnel = pow(1.0 - max(dot(N, V), 0.0), 2.0);
    windowColor = mix(windowColor, float3(0.7, 0.8, 0.9), fresnel * 0.3);

    // Final color
    float3 color = mix(wallColor, windowColor, isWindow);

    // Basic lighting on wall
    float3 L = normalize(uniforms.lightDirection);
    float diffuse = max(dot(N, L), 0.0) * 0.5 + 0.5;
    color *= diffuse;

    return float4(color, 1.0);
}
