import Foundation
import Metal
import simd

/// 청크 관리자 - 카메라 위치에 따른 청크 로드/언로드
@MainActor
final class ChunkManager {

    // MARK: - Constants

    private let loadRadius: Float = 10000  // 로드 반경 (미터) - 모든 데이터 포함
    private let unloadRadius: Float = 15000  // 언로드 반경 (미터)
    private let maxLoadedChunks = 100  // 모든 청크 로드 가능

    // MARK: - Properties

    private let device: MTLDevice
    private let loader: ChunkLoader
    private var loadedChunks: [ChunkID: RenderableChunk] = [:]
    private var loadingChunks: Set<ChunkID> = []

    weak var delegate: ChunkManagerDelegate?

    // MARK: - Initialization

    init(device: MTLDevice) {
        self.device = device
        self.loader = ChunkLoader(device: device)
    }

    // MARK: - Setup

    func loadIndex() throws {
        try loader.loadIndex()
        print("ChunkManager: Index loaded with \(loader.getAllChunkIDs().count) chunks")
    }

    // MARK: - Update

    func update(cameraPosition: SIMD3<Float>) {
        // 언로드할 청크 찾기
        let chunksToUnload = loadedChunks.filter { id, chunk in
            let distance = chunk.distanceToCamera(cameraPosition)
            return distance > unloadRadius
        }.map { $0.key }

        // 청크 언로드
        for id in chunksToUnload {
            unloadChunk(id: id)
        }

        // 로드할 청크 찾기
        let nearbyChunks = loader.getChunksInRange(center: cameraPosition, radius: loadRadius)

        for id in nearbyChunks {
            if loadedChunks[id] == nil && !loadingChunks.contains(id) {
                loadChunkAsync(id: id)
            }
        }
    }

    // MARK: - Chunk Loading

    private func loadChunkAsync(id: ChunkID) {
        guard loadedChunks.count < maxLoadedChunks else { return }

        loadingChunks.insert(id)

        Task.detached { [weak self, id] in
            do {
                guard let self = self else { return }
                let loadedChunk = try await MainActor.run {
                    try self.loader.loadChunk(id: id)
                }

                if let loadedChunk = loadedChunk {
                    let renderableChunk = await MainActor.run {
                        self.createRenderableChunk(from: loadedChunk)
                    }

                    await MainActor.run {
                        self.loadingChunks.remove(id)
                        self.loadedChunks[id] = renderableChunk
                        self.delegate?.chunkManager(self, didLoadChunk: id)
//                        print("Loaded chunk (\(id.x), \(id.y)): \(loadedChunk.buildings.count) buildings, \(loadedChunk.roads.count) roads")
                    }
                } else {
                    await MainActor.run {
                        self.loadingChunks.remove(id)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.loadingChunks.remove(id)
                    print("Failed to load chunk (\(id.x), \(id.y)): \(error)")
                }
            }
        }
    }

    private func unloadChunk(id: ChunkID) {
        loadedChunks.removeValue(forKey: id)
        delegate?.chunkManager(self, didUnloadChunk: id)
        print("Unloaded chunk (\(id.x), \(id.y))")
    }

    // MARK: - GPU Buffer Creation

    private func createRenderableChunk(from chunk: LoadedChunk) -> RenderableChunk {
        var buildingMeshes: [RenderableMesh] = []
        var roadMeshes: [RenderableMesh] = []

        // 건물 메시 생성
        // 주의: 버텍스가 이미 월드 좌표로 저장되어 있으므로 항등 행렬 사용
        for (index, building) in chunk.buildings.enumerated() {
            if let mesh = createMesh(vertices: building.vertices, indices: building.indices) {
                // 건물 기본 색상 (회색 계열)
                let buildingColor = SIMD4<Float>(0.7, 0.7, 0.75, 1.0)
                let renderableMesh = RenderableMesh(
                    mesh: mesh,
                    modelMatrix: simd_float4x4.identity,  // 버텍스가 이미 월드 좌표
                    color: buildingColor
                )
                buildingMeshes.append(renderableMesh)

//                if index == 0 {
//                    print("Building mesh created: \(building.vertices.count) vertices, \(building.indices.count) indices, pos=\(building.position)")
//                }
            }
        }

        // 도로 메시 생성
        for (index, road) in chunk.roads.enumerated() {
            if let mesh = createMesh(vertices: road.vertices, indices: road.indices) {
                let roadType = RoadType(rawValue: road.roadType) ?? .residential
                let renderableMesh = RenderableMesh(
                    mesh: mesh,
                    modelMatrix: simd_float4x4.identity,
                    color: roadType.color
                )
                roadMeshes.append(renderableMesh)

//                if index == 0 {
//                    print("Road mesh created: \(road.vertices.count) vertices, \(road.indices.count) indices")
//                    // Debug: Print first few vertex positions
//                    for (i, v) in road.vertices.prefix(4).enumerated() {
//                        print("  Road vertex[\(i)]: pos=(\(v.position.x), \(v.position.y), \(v.position.z))")
//                    }
//                }
            }
        }

//        print("Chunk \(chunk.id): Created \(buildingMeshes.count) building meshes, \(roadMeshes.count) road meshes")

        return RenderableChunk(
            id: chunk.id,
            bounds: chunk.bounds,
            buildings: buildingMeshes,
            roads: roadMeshes
        )
    }

    private func createMesh(vertices: [Vertex], indices: [UInt32]) -> Mesh? {
        guard !vertices.isEmpty && !indices.isEmpty else { return nil }

        // Vertex 데이터를 GPU 형식으로 변환
        var gpuVertices: [GPUVertex] = []
        for v in vertices {
            gpuVertices.append(GPUVertex(
                position: v.position,
                normal: v.normal,
                texCoord: v.texCoord
            ))
        }

        guard let vertexBuffer = device.makeBuffer(
            bytes: gpuVertices,
            length: gpuVertices.count * MemoryLayout<GPUVertex>.stride,
            options: .storageModeShared
        ) else { return nil }

        guard let indexBuffer = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else { return nil }

        return Mesh(
            vertexBuffer: vertexBuffer,
            indexBuffer: indexBuffer,
            indexCount: indices.count,
            primitiveType: .triangle
        )
    }

    private func colorFromUInt32(_ value: UInt32) -> SIMD4<Float> {
        let r = Float((value >> 24) & 0xFF) / 255.0
        let g = Float((value >> 16) & 0xFF) / 255.0
        let b = Float((value >> 8) & 0xFF) / 255.0
        let a = Float(value & 0xFF) / 255.0
        return SIMD4(r, g, b, a)
    }

    // MARK: - Accessors

    func getLoadedChunks() -> [RenderableChunk] {
        Array(loadedChunks.values)
    }

    func getVisibleChunks(frustum: Frustum) -> [RenderableChunk] {
        loadedChunks.values.filter { chunk in
            frustum.intersects(bounds: chunk.bounds)
        }
    }

    var loadedChunkCount: Int {
        loadedChunks.count
    }

    var loadingChunkCount: Int {
        loadingChunks.count
    }
}

// MARK: - Delegate Protocol

@MainActor
protocol ChunkManagerDelegate: AnyObject {
    func chunkManager(_ manager: ChunkManager, didLoadChunk id: ChunkID)
    func chunkManager(_ manager: ChunkManager, didUnloadChunk id: ChunkID)
}

// MARK: - Renderable Types

struct RenderableChunk: @unchecked Sendable {
    let id: ChunkID
    let bounds: ChunkBounds
    let buildings: [RenderableMesh]
    let roads: [RenderableMesh]

    func distanceToCamera(_ cameraPosition: SIMD3<Float>) -> Float {
        bounds.distance(to: cameraPosition)
    }
}

struct RenderableMesh: @unchecked Sendable {
    let mesh: Mesh
    let modelMatrix: simd_float4x4
    let color: SIMD4<Float>
}

// MARK: - GPU Vertex

struct GPUVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var texCoord: SIMD2<Float>
}

// MARK: - Frustum

struct Frustum {
    var planes: [SIMD4<Float>] = []

    init(viewProjection: simd_float4x4) {
        // 프러스텀 평면 추출 (Gribb/Hartmann method)
        let m = viewProjection

        // Left
        planes.append(SIMD4(
            m[0][3] + m[0][0],
            m[1][3] + m[1][0],
            m[2][3] + m[2][0],
            m[3][3] + m[3][0]
        ))

        // Right
        planes.append(SIMD4(
            m[0][3] - m[0][0],
            m[1][3] - m[1][0],
            m[2][3] - m[2][0],
            m[3][3] - m[3][0]
        ))

        // Bottom
        planes.append(SIMD4(
            m[0][3] + m[0][1],
            m[1][3] + m[1][1],
            m[2][3] + m[2][1],
            m[3][3] + m[3][1]
        ))

        // Top
        planes.append(SIMD4(
            m[0][3] - m[0][1],
            m[1][3] - m[1][1],
            m[2][3] - m[2][1],
            m[3][3] - m[3][1]
        ))

        // Near
        planes.append(SIMD4(
            m[0][3] + m[0][2],
            m[1][3] + m[1][2],
            m[2][3] + m[2][2],
            m[3][3] + m[3][2]
        ))

        // Far
        planes.append(SIMD4(
            m[0][3] - m[0][2],
            m[1][3] - m[1][2],
            m[2][3] - m[2][2],
            m[3][3] - m[3][2]
        ))

        // 정규화
        planes = planes.map { plane in
            let length = simd_length(SIMD3(plane.x, plane.y, plane.z))
            return plane / length
        }
    }

    func intersects(bounds: ChunkBounds) -> Bool {
        let corners = [
            SIMD3<Float>(bounds.minX, 0, bounds.minZ),
            SIMD3<Float>(bounds.maxX, 0, bounds.minZ),
            SIMD3<Float>(bounds.minX, 0, bounds.maxZ),
            SIMD3<Float>(bounds.maxX, 0, bounds.maxZ),
            SIMD3<Float>(bounds.minX, 100, bounds.minZ),
            SIMD3<Float>(bounds.maxX, 100, bounds.minZ),
            SIMD3<Float>(bounds.minX, 100, bounds.maxZ),
            SIMD3<Float>(bounds.maxX, 100, bounds.maxZ)
        ]

        for plane in planes {
            var allOutside = true
            for corner in corners {
                let distance = simd_dot(SIMD3(plane.x, plane.y, plane.z), corner) + plane.w
                if distance >= 0 {
                    allOutside = false
                    break
                }
            }
            if allOutside {
                return false
            }
        }

        return true
    }
}

// MARK: - Matrix Extension

extension simd_float4x4 {
    static var identity: simd_float4x4 {
        matrix_identity_float4x4
    }
}
