import simd
import Foundation
import UIKit

/// 3D 공간에서의 Ray 구조체
struct Ray {
    let origin: SIMD3<Float>
    let direction: SIMD3<Float>

    /// Ray 위의 특정 거리에 있는 점 반환
    func point(at t: Float) -> SIMD3<Float> {
        origin + direction * t
    }
}

/// Ray Casting 유틸리티
struct RayCaster {

    /// 화면 좌표에서 월드 공간 Ray 생성
    /// - Parameters:
    ///   - screenPoint: 화면 좌표 (포인트 단위)
    ///   - viewportSize: 뷰포트 크기
    ///   - viewMatrix: 뷰 매트릭스 (flipZ 적용된)
    ///   - projectionMatrix: 프로젝션 매트릭스
    /// - Returns: 월드 공간의 Ray
    static func createRay(
        screenPoint: CGPoint,
        viewportSize: CGSize,
        viewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4
    ) -> Ray {
        // Screen scale 적용 (Retina)
        let scale = UIScreen.main.scale
        let pixelX = Float(screenPoint.x * scale)
        let pixelY = Float(screenPoint.y * scale)
        let viewportWidth = Float(viewportSize.width)
        let viewportHeight = Float(viewportSize.height)

        // Screen -> NDC 변환
        // NDC: x, y는 -1~1, z는 0~1 (Reversed-Z: near=1, far=0)
        let ndcX = (2.0 * pixelX / viewportWidth) - 1.0
        let ndcY = 1.0 - (2.0 * pixelY / viewportHeight)  // Y축 반전

        // 역행렬 계산
        let inverseProjection = projectionMatrix.inverse
        let inverseView = viewMatrix.inverse

        // NDC -> View Space (near plane, z=1 for Reversed-Z)
        let nearPointNDC = SIMD4<Float>(ndcX, ndcY, 1.0, 1.0)  // near = 1.0
        let farPointNDC = SIMD4<Float>(ndcX, ndcY, 0.0, 1.0)   // far = 0.0

        // NDC -> View Space
        var nearPointView = inverseProjection * nearPointNDC
        nearPointView /= nearPointView.w
        var farPointView = inverseProjection * farPointNDC
        farPointView /= farPointView.w

        // View Space -> World Space
        let nearPointWorld = inverseView * nearPointView
        let farPointWorld = inverseView * farPointView

        let origin = SIMD3<Float>(nearPointWorld.x, nearPointWorld.y, nearPointWorld.z)
        let farPoint = SIMD3<Float>(farPointWorld.x, farPointWorld.y, farPointWorld.z)
        let direction = simd_normalize(farPoint - origin)

        return Ray(origin: origin, direction: direction)
    }

    /// Ray-AABB 교차 테스트 (Slab method)
    /// - Returns: 교차 시 (진입 거리, 탈출 거리), 없으면 nil
    static func intersectAABB(
        ray: Ray,
        min: SIMD3<Float>,
        max: SIMD3<Float>
    ) -> (tMin: Float, tMax: Float)? {
        var tMin: Float = -.greatestFiniteMagnitude
        var tMax: Float = .greatestFiniteMagnitude

        for i in 0..<3 {
            if abs(ray.direction[i]) < 1e-8 {
                // Ray가 이 축에 평행
                if ray.origin[i] < min[i] || ray.origin[i] > max[i] {
                    return nil
                }
            } else {
                let ood = 1.0 / ray.direction[i]
                var t1 = (min[i] - ray.origin[i]) * ood
                var t2 = (max[i] - ray.origin[i]) * ood

                if t1 > t2 { swap(&t1, &t2) }

                tMin = Swift.max(tMin, t1)
                tMax = Swift.min(tMax, t2)

                if tMin > tMax { return nil }
            }
        }

        // 음수 거리는 Ray 뒤쪽
        if tMax < 0 { return nil }

        return (Swift.max(0, tMin), tMax)
    }

    /// Ray-삼각형 교차 테스트 (Möller–Trumbore algorithm)
    /// - Returns: 교차 시 거리, 없으면 nil
    static func intersectTriangle(
        ray: Ray,
        v0: SIMD3<Float>,
        v1: SIMD3<Float>,
        v2: SIMD3<Float>
    ) -> Float? {
        let epsilon: Float = 1e-6

        let edge1 = v1 - v0
        let edge2 = v2 - v0
        let h = cross(ray.direction, edge2)
        let a = dot(edge1, h)

        // Ray가 삼각형과 평행
        if abs(a) < epsilon { return nil }

        let f = 1.0 / a
        let s = ray.origin - v0
        let u = f * dot(s, h)

        if u < 0.0 || u > 1.0 { return nil }

        let q = cross(s, edge1)
        let v = f * dot(ray.direction, q)

        if v < 0.0 || u + v > 1.0 { return nil }

        let t = f * dot(edge2, q)

        // 양수 거리만 유효 (Ray 앞쪽)
        if t > epsilon {
            return t
        }

        return nil
    }

    /// 바운딩 박스의 Min/Max 좌표 계산
    static func computeBounds(vertices: [SIMD3<Float>]) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard !vertices.isEmpty else { return nil }

        var minBound = vertices[0]
        var maxBound = vertices[0]

        for v in vertices {
            minBound = SIMD3<Float>(
                Swift.min(minBound.x, v.x),
                Swift.min(minBound.y, v.y),
                Swift.min(minBound.z, v.z)
            )
            maxBound = SIMD3<Float>(
                Swift.max(maxBound.x, v.x),
                Swift.max(maxBound.y, v.y),
                Swift.max(maxBound.z, v.z)
            )
        }

        return (minBound, maxBound)
    }
}
