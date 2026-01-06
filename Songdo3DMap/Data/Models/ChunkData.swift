import Foundation
import simd

/// 청크 인덱스 메타데이터
struct ChunkIndex: Codable {
    let version: String
    let origin: Origin
    let chunkSizeMeters: Float
    let chunks: [ChunkInfo]

    enum CodingKeys: String, CodingKey {
        case version
        case origin
        case chunkSizeMeters = "chunk_size_meters"
        case chunks
    }

    struct Origin: Codable {
        let latitude: Double
        let longitude: Double
    }

    struct ChunkInfo: Codable {
        let id: String
        let file: String
        let x: Int
        let y: Int
        let bounds: Bounds
        let buildingCount: Int
        let roadCount: Int

        enum CodingKeys: String, CodingKey {
            case id, file, x, y, bounds
            case buildingCount = "building_count"
            case roadCount = "road_count"
        }

        struct Bounds: Codable {
            let minX: Float
            let minZ: Float
            let maxX: Float
            let maxZ: Float

            enum CodingKeys: String, CodingKey {
                case minX = "min_x"
                case minZ = "min_z"
                case maxX = "max_x"
                case maxZ = "max_z"
            }
        }
    }
}

/// 청크 ID
struct ChunkID: Hashable {
    let x: Int
    let y: Int

    init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }

    init(from info: ChunkIndex.ChunkInfo) {
        self.x = info.x
        self.y = info.y
    }
}

/// 로드된 청크 데이터
struct LoadedChunk {
    let id: ChunkID
    let bounds: ChunkBounds
    let buildings: [BuildingData]
    let roads: [RoadData]

    var isEmpty: Bool {
        buildings.isEmpty && roads.isEmpty
    }
}

/// 청크 경계
struct ChunkBounds {
    let minX: Float
    let minZ: Float
    let maxX: Float
    let maxZ: Float

    var center: SIMD3<Float> {
        SIMD3(
            (minX + maxX) / 2,
            0,
            (minZ + maxZ) / 2
        )
    }

    var size: SIMD2<Float> {
        SIMD2(maxX - minX, maxZ - minZ)
    }

    func contains(_ point: SIMD3<Float>) -> Bool {
        point.x >= minX && point.x < maxX &&
        point.z >= minZ && point.z < maxZ
    }

    func distance(to point: SIMD3<Float>) -> Float {
        let cx = (minX + maxX) / 2
        let cz = (minZ + maxZ) / 2
        let dx = point.x - cx
        let dz = point.z - cz
        return sqrt(dx * dx + dz * dz)
    }
}

/// 건물 데이터
struct BuildingData {
    let position: SIMD3<Float>
    let rotation: Float
    let scale: SIMD3<Float>
    let height: Float
    let textureId: UInt16
    let flags: UInt16
    let color: UInt32
    let name: String?  // 건물 이름 (OSM name 태그)

    let vertices: [Vertex]
    let indices: [UInt32]

    var modelMatrix: simd_float4x4 {
        let translation = simd_float4x4.translation(position)
        let rotation = simd_float4x4.rotationY(self.rotation)
        let scale = simd_float4x4.scale(self.scale)
        return translation * rotation * scale
    }
}

/// 도로 데이터
struct RoadData {
    let roadType: UInt8
    let lanes: UInt8
    let width: Float
    let pointCount: UInt32
    let name: String?  // 도로 이름 (OSM name 태그)

    let vertices: [Vertex]
    let indices: [UInt32]
}

/// 도로 타입
enum RoadType: UInt8 {
    case highway = 0
    case primary = 1
    case secondary = 2
    case residential = 3
    case path = 4

    var color: SIMD4<Float> {
        switch self {
        case .highway: return SIMD4(0.25, 0.25, 0.28, 1.0)
        case .primary: return SIMD4(0.35, 0.35, 0.38, 1.0)
        case .secondary: return SIMD4(0.45, 0.45, 0.48, 1.0)
        case .residential: return SIMD4(0.5, 0.5, 0.52, 1.0)
        case .path: return SIMD4(0.6, 0.58, 0.55, 1.0)
        }
    }

    var displayName: String {
        switch self {
        case .highway: return "고속도로"
        case .primary: return "주간선도로"
        case .secondary: return "보조간선도로"
        case .residential: return "주거도로"
        case .path: return "보행로"
        }
    }
}
