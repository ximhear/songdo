import Foundation
import Metal
import simd

/// 박스 메시 생성기 (마커용)
struct BoxGenerator {

    /// 박스 메시 생성
    static func generate(
        width: Float,
        height: Float,
        depth: Float,
        device: MTLDevice
    ) -> Mesh? {
        let hw = width / 2   // half width
        let hd = depth / 2   // half depth

        // 8개 코너 위치
        let positions: [SIMD3<Float>] = [
            // 하단 4개
            SIMD3(-hw, 0, -hd),      // 0: 좌하후
            SIMD3( hw, 0, -hd),      // 1: 우하후
            SIMD3( hw, 0,  hd),      // 2: 우하전
            SIMD3(-hw, 0,  hd),      // 3: 좌하전
            // 상단 4개
            SIMD3(-hw, height, -hd), // 4: 좌상후
            SIMD3( hw, height, -hd), // 5: 우상후
            SIMD3( hw, height,  hd), // 6: 우상전
            SIMD3(-hw, height,  hd), // 7: 좌상전
        ]

        var vertices: [GPUVertex] = []
        var indices: [UInt32] = []

        // 6개 면 정의 (각 면마다 4개 버텍스, 법선 방향)
        let faces: [(corners: [Int], normal: SIMD3<Float>)] = [
            // 전면 (Z+)
            (corners: [3, 2, 6, 7], normal: SIMD3(0, 0, 1)),
            // 후면 (Z-)
            (corners: [1, 0, 4, 5], normal: SIMD3(0, 0, -1)),
            // 우측 (X+)
            (corners: [2, 1, 5, 6], normal: SIMD3(1, 0, 0)),
            // 좌측 (X-)
            (corners: [0, 3, 7, 4], normal: SIMD3(-1, 0, 0)),
            // 상단 (Y+)
            (corners: [7, 6, 5, 4], normal: SIMD3(0, 1, 0)),
            // 하단 (Y-)
            (corners: [0, 1, 2, 3], normal: SIMD3(0, -1, 0)),
        ]

        for face in faces {
            let baseIndex = UInt32(vertices.count)

            // 4개 버텍스 추가
            for (i, cornerIdx) in face.corners.enumerated() {
                let uv: SIMD2<Float>
                switch i {
                case 0: uv = SIMD2(0, 0)
                case 1: uv = SIMD2(1, 0)
                case 2: uv = SIMD2(1, 1)
                case 3: uv = SIMD2(0, 1)
                default: uv = SIMD2(0, 0)
                }

                vertices.append(GPUVertex(
                    position: positions[cornerIdx],
                    normal: face.normal,
                    texCoord: uv
                ))
            }

            // 2개 삼각형 (CCW winding)
            indices.append(baseIndex)
            indices.append(baseIndex + 1)
            indices.append(baseIndex + 2)

            indices.append(baseIndex)
            indices.append(baseIndex + 2)
            indices.append(baseIndex + 3)
        }

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
