import simd

/// 3D 맵 카메라 (Orbit 모드 기본)
final class Camera {

    // MARK: - Camera Modes

    enum Mode {
        case orbit      // 타겟 중심 회전 (기본)
        case freefly    // 자유 비행
        case topDown    // 2D 맵 스타일
    }

    // MARK: - Properties

    var mode: Mode = .orbit

    // Position and orientation
    var position: SIMD3<Float> = SIMD3(0, 500, 500)
    var target: SIMD3<Float> = SIMD3(0, 0, 0)
    var up: SIMD3<Float> = SIMD3(0, 1, 0)

    // Orbit mode parameters
    var pitch: Float = -45  // 상하 각도 (-90 ~ 0)
    var yaw: Float = 0      // 좌우 각도
    var distance: Float = 700  // 타겟으로부터 거리

    // Projection parameters
    var fov: Float = 60
    var aspectRatio: Float = 1
    var nearPlane: Float = 10.0   // 더 증가: depth 정밀도 개선
    var farPlane: Float = 20000   // 더 감소: depth 정밀도 개선
    // 비율: 2000:1 (이전 6000:1, 최초 100,000:1)

    // Constraints
    var minDistance: Float = 10
    var maxDistance: Float = 20000  // 전체 송도 (~13km) 볼 수 있도록
    var minPitch: Float = -89
    var maxPitch: Float = -10

    // MARK: - Computed Matrices

    var viewMatrix: simd_float4x4 {
        switch mode {
        case .orbit:
            return computeOrbitViewMatrix()
        case .freefly:
            return computeFreeflyViewMatrix()
        case .topDown:
            return computeTopDownViewMatrix()
        }
    }

    var projectionMatrix: simd_float4x4 {
        return simd_float4x4.perspective(
            fovRadians: fov * .pi / 180,
            aspect: aspectRatio,
            near: nearPlane,
            far: farPlane
        )
    }

    var viewProjectionMatrix: simd_float4x4 {
        return projectionMatrix * viewMatrix
    }

    // MARK: - View Matrix Computation

    private func computeOrbitViewMatrix() -> simd_float4x4 {
        // 구면 좌표계로 카메라 위치 계산
        let pitchRad = pitch * .pi / 180
        let yawRad = yaw * .pi / 180

        let x = distance * cos(pitchRad) * sin(yawRad)
        let y = distance * sin(-pitchRad)
        let z = distance * cos(pitchRad) * cos(yawRad)

        position = target + SIMD3(x, y, z)

        return simd_float4x4.lookAt(eye: position, target: target, up: up)
    }

    private func computeFreeflyViewMatrix() -> simd_float4x4 {
        return simd_float4x4.lookAt(eye: position, target: target, up: up)
    }

    private func computeTopDownViewMatrix() -> simd_float4x4 {
        // 수직 하향 뷰
        let topDownPosition = SIMD3<Float>(target.x, distance, target.z)
        let topDownUp = SIMD3<Float>(0, 0, -1)
        return simd_float4x4.lookAt(eye: topDownPosition, target: target, up: topDownUp)
    }

    // MARK: - Frustum

    var frustumPlanes: [SIMD4<Float>] {
        let m = viewProjectionMatrix
        var planes = [SIMD4<Float>](repeating: .zero, count: 6)

        // Left
        planes[0] = SIMD4(
            m[0][3] + m[0][0],
            m[1][3] + m[1][0],
            m[2][3] + m[2][0],
            m[3][3] + m[3][0]
        )

        // Right
        planes[1] = SIMD4(
            m[0][3] - m[0][0],
            m[1][3] - m[1][0],
            m[2][3] - m[2][0],
            m[3][3] - m[3][0]
        )

        // Bottom
        planes[2] = SIMD4(
            m[0][3] + m[0][1],
            m[1][3] + m[1][1],
            m[2][3] + m[2][1],
            m[3][3] + m[3][1]
        )

        // Top
        planes[3] = SIMD4(
            m[0][3] - m[0][1],
            m[1][3] - m[1][1],
            m[2][3] - m[2][1],
            m[3][3] - m[3][1]
        )

        // Near
        planes[4] = SIMD4(
            m[0][2],
            m[1][2],
            m[2][2],
            m[3][2]
        )

        // Far
        planes[5] = SIMD4(
            m[0][3] - m[0][2],
            m[1][3] - m[1][2],
            m[2][3] - m[2][2],
            m[3][3] - m[3][2]
        )

        // 정규화
        for i in 0..<6 {
            let length = simd_length(SIMD3(planes[i].x, planes[i].y, planes[i].z))
            planes[i] /= length
        }

        return planes
    }
}

// MARK: - Matrix Extensions

extension simd_float4x4 {

    /// Look-at 행렬 생성
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = normalize(eye - target)
        let x = normalize(cross(up, z))
        let y = cross(z, x)

        return simd_float4x4(
            SIMD4(x.x, y.x, z.x, 0),
            SIMD4(x.y, y.y, z.y, 0),
            SIMD4(x.z, y.z, z.z, 0),
            SIMD4(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        )
    }

    /// 원근 투영 행렬 생성 (Reversed-Z)
    /// Reversed-Z: near → 1.0, far → 0.0 으로 매핑하여 depth 정밀도 대폭 개선
    static func perspective(fovRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovRadians * 0.5)
        let x = y / aspect

        // Reversed-Z projection matrix
        // Maps: near plane → depth 1.0, far plane → depth 0.0
        return simd_float4x4(
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, near / (far - near), -1),
            SIMD4(0, 0, far * near / (far - near), 0)
        )
    }

    /// 직교 투영 행렬 생성
    static func orthographic(
        left: Float, right: Float,
        bottom: Float, top: Float,
        near: Float, far: Float
    ) -> simd_float4x4 {
        let sx = 2 / (right - left)
        let sy = 2 / (top - bottom)
        let sz = 1 / (near - far)
        let tx = (left + right) / (left - right)
        let ty = (top + bottom) / (bottom - top)
        let tz = near / (near - far)

        return simd_float4x4(
            SIMD4(sx, 0, 0, 0),
            SIMD4(0, sy, 0, 0),
            SIMD4(0, 0, sz, 0),
            SIMD4(tx, ty, tz, 1)
        )
    }

    /// 이동 행렬 생성
    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        return simd_float4x4(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(t.x, t.y, t.z, 1)
        )
    }

    /// Y축 회전 행렬 생성
    static func rotationY(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        return simd_float4x4(
            SIMD4(c, 0, s, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(-s, 0, c, 0),
            SIMD4(0, 0, 0, 1)
        )
    }

    /// 스케일 행렬 생성
    static func scale(_ s: SIMD3<Float>) -> simd_float4x4 {
        return simd_float4x4(
            SIMD4(s.x, 0, 0, 0),
            SIMD4(0, s.y, 0, 0),
            SIMD4(0, 0, s.z, 0),
            SIMD4(0, 0, 0, 1)
        )
    }
}
