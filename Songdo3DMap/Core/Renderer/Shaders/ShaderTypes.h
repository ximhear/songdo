#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// Buffer indices
typedef enum {
    BufferIndexVertices = 0,
    BufferIndexUniforms = 1,
    BufferIndexInstances = 2,
    BufferIndexMaterials = 3,
    BufferIndexModelMatrix = 4
} BufferIndex;

// Texture indices
typedef enum {
    TextureIndexColor = 0,
    TextureIndexNormal = 1,
    TextureIndexHeightmap = 2
} TextureIndex;

// Vertex attribute indices
typedef enum {
    VertexAttributePosition = 0,
    VertexAttributeNormal = 1,
    VertexAttributeTexcoord = 2,
    VertexAttributeColor = 3
} VertexAttribute;

// Basic vertex structure
typedef struct {
    simd_float3 position;
    simd_float3 normal;
    simd_float2 texCoord;
} Vertex;

// Per-frame uniforms
typedef struct {
    simd_float4x4 viewMatrix;
    simd_float4x4 projectionMatrix;
    simd_float4x4 viewProjectionMatrix;
    simd_float3 cameraPosition;
    float time;
    simd_float3 lightDirection;
    float padding1;
    simd_float3 lightColor;
    float padding2;
    simd_float3 ambientColor;
    float padding3;
} Uniforms;

// Building instance data
typedef struct {
    simd_float4x4 modelMatrix;
    simd_float4 color;
    uint32_t textureIndex;
    float height;
    uint32_t lodLevel;
    uint32_t padding;
} BuildingInstance;

// Terrain uniforms
typedef struct {
    simd_float2 terrainOrigin;
    simd_float2 terrainSize;
    float heightScale;
    float textureTiling;
    uint32_t gridWidth;
    uint32_t gridHeight;
} TerrainUniforms;

// Road vertex
typedef struct {
    simd_float3 position;
    simd_float2 texCoord;
    float width;
    uint32_t roadType;
} RoadVertex;

// Frustum planes for culling (6 planes: left, right, bottom, top, near, far)
typedef struct {
    simd_float4 planes[6];
} FrustumPlanes;

// Indirect draw arguments (for GPU-driven rendering)
typedef struct {
    uint32_t indexCount;
    uint32_t instanceCount;
    uint32_t indexStart;
    int32_t baseVertex;
    uint32_t baseInstance;
} DrawIndexedArguments;

#endif /* ShaderTypes_h */
