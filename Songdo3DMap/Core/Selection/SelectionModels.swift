import simd
import Foundation

/// 선택 가능한 객체 타입
enum SelectableObjectType: Equatable {
    case building
    case road(RoadType)
}

/// 선택된 건물 정보
struct BuildingSelectionInfo: Identifiable, Equatable {
    let id = UUID()
    let position: SIMD3<Float>
    let height: Float
    let width: Float
    let depth: Float
    let name: String?
    let chunkId: ChunkID
    let indexInChunk: Int

    static func == (lhs: BuildingSelectionInfo, rhs: BuildingSelectionInfo) -> Bool {
        lhs.id == rhs.id
    }
}

/// 선택된 도로 정보
struct RoadSelectionInfo: Identifiable, Equatable {
    let id = UUID()
    let roadType: RoadType
    let lanes: Int
    let width: Float
    let name: String?
    let chunkId: ChunkID
    let indexInChunk: Int

    static func == (lhs: RoadSelectionInfo, rhs: RoadSelectionInfo) -> Bool {
        lhs.id == rhs.id
    }
}

/// 선택 결과
enum SelectionResult: Equatable {
    case building(BuildingSelectionInfo)
    case road(RoadSelectionInfo)
    case none

    static func == (lhs: SelectionResult, rhs: SelectionResult) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case (.building(let a), .building(let b)):
            return a == b
        case (.road(let a), .road(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// 히트 테스트 결과
struct HitTestResult {
    let objectType: SelectableObjectType
    let distance: Float
    let hitPoint: SIMD3<Float>
    let chunkId: ChunkID
    let objectIndex: Int
    let buildingInfo: BuildingSelectionInfo?
    let roadInfo: RoadSelectionInfo?

    func toSelectionResult() -> SelectionResult {
        if let building = buildingInfo {
            return .building(building)
        } else if let road = roadInfo {
            return .road(road)
        }
        return .none
    }
}
