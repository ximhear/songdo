import Foundation
import Metal
import simd

/// 원기둥 메시 생성기
struct CylinderGenerator {

    /// 원기둥 메시 생성
    /// - Parameters:
    ///   - radius: 반지름 (미터)
    ///   - height: 높이 (미터)
    ///   - segments: 원주 분할 수
    ///   - device: Metal 디바이스
    /// - Returns: 생성된 메시
    static func generate(
        radius: Float,
        height: Float,
        segments: Int = 32,
        device: MTLDevice
    ) -> Mesh? {
        var vertices: [GPUVertex] = []
        var indices: [UInt32] = []

        let segmentAngle = (2.0 * Float.pi) / Float(segments)

        // 측면 버텍스
        for i in 0...segments {
            let angle = Float(i) * segmentAngle
            let x = cos(angle) * radius
            let z = sin(angle) * radius
            let nx = cos(angle)
            let nz = sin(angle)

            // 하단
            vertices.append(GPUVertex(
                position: SIMD3<Float>(x, 0, z),
                normal: SIMD3<Float>(nx, 0, nz),
                texCoord: SIMD2<Float>(Float(i) / Float(segments), 0)
            ))

            // 상단
            vertices.append(GPUVertex(
                position: SIMD3<Float>(x, height, z),
                normal: SIMD3<Float>(nx, 0, nz),
                texCoord: SIMD2<Float>(Float(i) / Float(segments), 1)
            ))
        }

        // 측면 인덱스
        for i in 0..<segments {
            let base = UInt32(i * 2)
            // 삼각형 1
            indices.append(base)
            indices.append(base + 1)
            indices.append(base + 2)
            // 삼각형 2
            indices.append(base + 1)
            indices.append(base + 3)
            indices.append(base + 2)
        }

        // 상단 캡 중심점
        let topCenterIndex = UInt32(vertices.count)
        vertices.append(GPUVertex(
            position: SIMD3<Float>(0, height, 0),
            normal: SIMD3<Float>(0, 1, 0),
            texCoord: SIMD2<Float>(0.5, 0.5)
        ))

        // 상단 캡 버텍스
        let topCapStartIndex = UInt32(vertices.count)
        for i in 0...segments {
            let angle = Float(i) * segmentAngle
            let x = cos(angle) * radius
            let z = sin(angle) * radius

            vertices.append(GPUVertex(
                position: SIMD3<Float>(x, height, z),
                normal: SIMD3<Float>(0, 1, 0),
                texCoord: SIMD2<Float>(cos(angle) * 0.5 + 0.5, sin(angle) * 0.5 + 0.5)
            ))
        }

        // 상단 캡 인덱스
        for i in 0..<segments {
            indices.append(topCenterIndex)
            indices.append(topCapStartIndex + UInt32(i))
            indices.append(topCapStartIndex + UInt32(i + 1))
        }

        // 하단 캡 중심점
        let bottomCenterIndex = UInt32(vertices.count)
        vertices.append(GPUVertex(
            position: SIMD3<Float>(0, 0, 0),
            normal: SIMD3<Float>(0, -1, 0),
            texCoord: SIMD2<Float>(0.5, 0.5)
        ))

        // 하단 캡 버텍스
        let bottomCapStartIndex = UInt32(vertices.count)
        for i in 0...segments {
            let angle = Float(i) * segmentAngle
            let x = cos(angle) * radius
            let z = sin(angle) * radius

            vertices.append(GPUVertex(
                position: SIMD3<Float>(x, 0, z),
                normal: SIMD3<Float>(0, -1, 0),
                texCoord: SIMD2<Float>(cos(angle) * 0.5 + 0.5, sin(angle) * 0.5 + 0.5)
            ))
        }

        // 하단 캡 인덱스 (반대 방향)
        for i in 0..<segments {
            indices.append(bottomCenterIndex)
            indices.append(bottomCapStartIndex + UInt32(i + 1))
            indices.append(bottomCapStartIndex + UInt32(i))
        }

        // GPU 버퍼 생성
        guard let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<GPUVertex>.stride,
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
}
