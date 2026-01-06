import simd
import Foundation
import Metal

/// Hit Testing 서비스
struct HitTester {

    /// 로드된 청크들에 대해 Hit Test 수행
    /// - Parameters:
    ///   - ray: 월드 공간의 Ray
    ///   - chunks: 테스트할 청크들
    /// - Returns: 가장 가까운 히트 결과 (없으면 nil)
    static func performHitTest(
        ray: Ray,
        chunks: [RenderableChunk]
    ) -> HitTestResult? {
        var closestHit: HitTestResult?
        var closestDistance: Float = .greatestFiniteMagnitude

        for chunk in chunks {
            // 청크 바운딩 박스 사전 검사
            let chunkMin = SIMD3<Float>(chunk.bounds.minX, 0, chunk.bounds.minZ)
            let chunkMax = SIMD3<Float>(chunk.bounds.maxX, 300, chunk.bounds.maxZ)  // 건물 최대 높이 300m 가정

            guard RayCaster.intersectAABB(ray: ray, min: chunkMin, max: chunkMax) != nil else {
                continue
            }

            // 건물 히트 테스트
            for (index, building) in chunk.buildings.enumerated() {
                if let result = hitTestBuilding(ray: ray, building: building, chunk: chunk, index: index) {
                    if result.distance < closestDistance {
                        closestDistance = result.distance
                        closestHit = result
                    }
                }
            }

            // 도로 히트 테스트
            for (index, road) in chunk.roads.enumerated() {
                if let result = hitTestRoad(ray: ray, road: road, chunk: chunk, index: index) {
                    if result.distance < closestDistance {
                        closestDistance = result.distance
                        closestHit = result
                    }
                }
            }
        }

        return closestHit
    }

    /// 건물 메시에 대한 히트 테스트
    private static func hitTestBuilding(
        ray: Ray,
        building: RenderableBuildingMesh,
        chunk: RenderableChunk,
        index: Int
    ) -> HitTestResult? {
        // 실제 버텍스 바운딩 박스 사용
        let bounds = building.bounds

        // AABB 교차 테스트
        guard let (tMin, _) = RayCaster.intersectAABB(ray: ray, min: bounds.min, max: bounds.max) else {
            return nil
        }

        let hitPoint = ray.point(at: tMin)

        let buildingInfo = BuildingSelectionInfo(
            position: building.position,
            height: building.height,
            width: building.width,
            depth: building.depth,
            name: building.name,
            chunkId: chunk.id,
            indexInChunk: index
        )

        return HitTestResult(
            objectType: .building,
            distance: tMin,
            hitPoint: hitPoint,
            chunkId: chunk.id,
            objectIndex: index,
            buildingInfo: buildingInfo,
            roadInfo: nil
        )
    }

    /// 도로 메시에 대한 히트 테스트
    private static func hitTestRoad(
        ray: Ray,
        road: RenderableRoadMesh,
        chunk: RenderableChunk,
        index: Int
    ) -> HitTestResult? {
        // 실제 버텍스 바운딩 박스 사용
        let bounds = road.bounds

        // AABB 교차 테스트
        guard let (tMin, _) = RayCaster.intersectAABB(ray: ray, min: bounds.min, max: bounds.max) else {
            return nil
        }

        let hitPoint = ray.point(at: tMin)

        let roadInfo = RoadSelectionInfo(
            roadType: road.roadType,
            lanes: road.lanes,
            width: road.width,
            name: road.name,
            chunkId: chunk.id,
            indexInChunk: index
        )

        return HitTestResult(
            objectType: .road(road.roadType),
            distance: tMin,
            hitPoint: hitPoint,
            chunkId: chunk.id,
            objectIndex: index,
            buildingInfo: nil,
            roadInfo: roadInfo
        )
    }
}
