import Metal
import simd

/// 범용 메시 구조체
struct Mesh {

    // MARK: - Properties

    var vertices: [Vertex]
    var indices: [UInt32]

    var vertexBuffer: MTLBuffer?
    var indexBuffer: MTLBuffer?
    var primitiveType: MTLPrimitiveType = .triangle

    var vertexCount: Int { vertices.count }
    var indexCount: Int { indices.count }

    // MARK: - Bounding Box

    var boundingBox: BoundingBox {
        guard !vertices.isEmpty else {
            return BoundingBox(min: .zero, max: .zero)
        }

        var minPoint = SIMD3<Float>(Float.infinity, Float.infinity, Float.infinity)
        var maxPoint = SIMD3<Float>(-Float.infinity, -Float.infinity, -Float.infinity)

        for vertex in vertices {
            minPoint = min(minPoint, vertex.position)
            maxPoint = max(maxPoint, vertex.position)
        }

        return BoundingBox(min: minPoint, max: maxPoint)
    }

    // MARK: - Initialization

    private var _indexCountOverride: Int? = nil

    init(vertices: [Vertex] = [], indices: [UInt32] = []) {
        self.vertices = vertices
        self.indices = indices
    }

    /// 이미 생성된 버퍼로 초기화
    init(vertexBuffer: MTLBuffer, indexBuffer: MTLBuffer, indexCount: Int, primitiveType: MTLPrimitiveType = .triangle) {
        self.vertices = []
        self.indices = []
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.primitiveType = primitiveType
        self._indexCountOverride = indexCount
    }

    var effectiveIndexCount: Int {
        _indexCountOverride ?? indices.count
    }

    // MARK: - Buffer Creation

    mutating func createBuffers(device: MTLDevice) {
        guard !vertices.isEmpty else { return }

        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<Vertex>.stride * vertices.count,
            options: .storageModeShared
        )
        vertexBuffer?.label = "Mesh Vertex Buffer"

        if !indices.isEmpty {
            indexBuffer = device.makeBuffer(
                bytes: indices,
                length: MemoryLayout<UInt32>.stride * indices.count,
                options: .storageModeShared
            )
            indexBuffer?.label = "Mesh Index Buffer"
        }
    }

    // MARK: - Primitive Generators

    /// 박스 메시 생성
    static func box(
        width: Float = 1,
        height: Float = 1,
        depth: Float = 1,
        device: MTLDevice? = nil
    ) -> Mesh {
        let hw = width / 2
        let hh = height / 2
        let hd = depth / 2

        // 24 vertices (4 per face for correct normals)
        let vertices: [Vertex] = [
            // Front face (+Z)
            Vertex(position: SIMD3(-hw, -hh,  hd), normal: SIMD3(0, 0, 1), texCoord: SIMD2(0, 1)),
            Vertex(position: SIMD3( hw, -hh,  hd), normal: SIMD3(0, 0, 1), texCoord: SIMD2(1, 1)),
            Vertex(position: SIMD3( hw,  hh,  hd), normal: SIMD3(0, 0, 1), texCoord: SIMD2(1, 0)),
            Vertex(position: SIMD3(-hw,  hh,  hd), normal: SIMD3(0, 0, 1), texCoord: SIMD2(0, 0)),

            // Back face (-Z)
            Vertex(position: SIMD3( hw, -hh, -hd), normal: SIMD3(0, 0, -1), texCoord: SIMD2(0, 1)),
            Vertex(position: SIMD3(-hw, -hh, -hd), normal: SIMD3(0, 0, -1), texCoord: SIMD2(1, 1)),
            Vertex(position: SIMD3(-hw,  hh, -hd), normal: SIMD3(0, 0, -1), texCoord: SIMD2(1, 0)),
            Vertex(position: SIMD3( hw,  hh, -hd), normal: SIMD3(0, 0, -1), texCoord: SIMD2(0, 0)),

            // Left face (-X)
            Vertex(position: SIMD3(-hw, -hh, -hd), normal: SIMD3(-1, 0, 0), texCoord: SIMD2(0, 1)),
            Vertex(position: SIMD3(-hw, -hh,  hd), normal: SIMD3(-1, 0, 0), texCoord: SIMD2(1, 1)),
            Vertex(position: SIMD3(-hw,  hh,  hd), normal: SIMD3(-1, 0, 0), texCoord: SIMD2(1, 0)),
            Vertex(position: SIMD3(-hw,  hh, -hd), normal: SIMD3(-1, 0, 0), texCoord: SIMD2(0, 0)),

            // Right face (+X)
            Vertex(position: SIMD3( hw, -hh,  hd), normal: SIMD3(1, 0, 0), texCoord: SIMD2(0, 1)),
            Vertex(position: SIMD3( hw, -hh, -hd), normal: SIMD3(1, 0, 0), texCoord: SIMD2(1, 1)),
            Vertex(position: SIMD3( hw,  hh, -hd), normal: SIMD3(1, 0, 0), texCoord: SIMD2(1, 0)),
            Vertex(position: SIMD3( hw,  hh,  hd), normal: SIMD3(1, 0, 0), texCoord: SIMD2(0, 0)),

            // Top face (+Y)
            Vertex(position: SIMD3(-hw,  hh,  hd), normal: SIMD3(0, 1, 0), texCoord: SIMD2(0, 1)),
            Vertex(position: SIMD3( hw,  hh,  hd), normal: SIMD3(0, 1, 0), texCoord: SIMD2(1, 1)),
            Vertex(position: SIMD3( hw,  hh, -hd), normal: SIMD3(0, 1, 0), texCoord: SIMD2(1, 0)),
            Vertex(position: SIMD3(-hw,  hh, -hd), normal: SIMD3(0, 1, 0), texCoord: SIMD2(0, 0)),

            // Bottom face (-Y)
            Vertex(position: SIMD3(-hw, -hh, -hd), normal: SIMD3(0, -1, 0), texCoord: SIMD2(0, 1)),
            Vertex(position: SIMD3( hw, -hh, -hd), normal: SIMD3(0, -1, 0), texCoord: SIMD2(1, 1)),
            Vertex(position: SIMD3( hw, -hh,  hd), normal: SIMD3(0, -1, 0), texCoord: SIMD2(1, 0)),
            Vertex(position: SIMD3(-hw, -hh,  hd), normal: SIMD3(0, -1, 0), texCoord: SIMD2(0, 0)),
        ]

        let indices: [UInt32] = [
            0, 1, 2, 0, 2, 3,       // Front
            4, 5, 6, 4, 6, 7,       // Back
            8, 9, 10, 8, 10, 11,    // Left
            12, 13, 14, 12, 14, 15, // Right
            16, 17, 18, 16, 18, 19, // Top
            20, 21, 22, 20, 22, 23  // Bottom
        ]

        var mesh = Mesh(vertices: vertices, indices: indices)
        if let device = device {
            mesh.createBuffers(device: device)
        }
        return mesh
    }

    /// 평면 메시 생성
    static func plane(
        width: Float = 1,
        depth: Float = 1,
        subdivisions: Int = 1,
        device: MTLDevice? = nil
    ) -> Mesh {
        var vertices: [Vertex] = []
        var indices: [UInt32] = []

        let hw = width / 2
        let hd = depth / 2
        let step = 1.0 / Float(subdivisions)

        for z in 0...subdivisions {
            for x in 0...subdivisions {
                let u = Float(x) * step
                let v = Float(z) * step
                let px = -hw + u * width
                let pz = -hd + v * depth

                vertices.append(Vertex(
                    position: SIMD3(px, 0, pz),
                    normal: SIMD3(0, 1, 0),
                    texCoord: SIMD2(u, v)
                ))
            }
        }

        let cols = subdivisions + 1
        for z in 0..<subdivisions {
            for x in 0..<subdivisions {
                let topLeft = UInt32(z * cols + x)
                let topRight = topLeft + 1
                let bottomLeft = topLeft + UInt32(cols)
                let bottomRight = bottomLeft + 1

                indices.append(contentsOf: [
                    topLeft, bottomLeft, topRight,
                    topRight, bottomLeft, bottomRight
                ])
            }
        }

        var mesh = Mesh(vertices: vertices, indices: indices)
        if let device = device {
            mesh.createBuffers(device: device)
        }
        return mesh
    }
}

// MARK: - BoundingBox

struct BoundingBox {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    var center: SIMD3<Float> {
        return (min + max) / 2
    }

    var size: SIMD3<Float> {
        return max - min
    }

    var radius: Float {
        return simd_length(size) / 2
    }

    func contains(_ point: SIMD3<Float>) -> Bool {
        return point.x >= min.x && point.x <= max.x &&
               point.y >= min.y && point.y <= max.y &&
               point.z >= min.z && point.z <= max.z
    }

    func intersects(_ other: BoundingBox) -> Bool {
        return min.x <= other.max.x && max.x >= other.min.x &&
               min.y <= other.max.y && max.y >= other.min.y &&
               min.z <= other.max.z && max.z >= other.min.z
    }

    func transformed(by matrix: simd_float4x4) -> BoundingBox {
        // Transform all 8 corners and compute new AABB
        let corners = [
            SIMD3<Float>(min.x, min.y, min.z),
            SIMD3<Float>(max.x, min.y, min.z),
            SIMD3<Float>(min.x, max.y, min.z),
            SIMD3<Float>(max.x, max.y, min.z),
            SIMD3<Float>(min.x, min.y, max.z),
            SIMD3<Float>(max.x, min.y, max.z),
            SIMD3<Float>(min.x, max.y, max.z),
            SIMD3<Float>(max.x, max.y, max.z)
        ]

        var newMin = SIMD3<Float>(Float.infinity, Float.infinity, Float.infinity)
        var newMax = SIMD3<Float>(-Float.infinity, -Float.infinity, -Float.infinity)

        for corner in corners {
            let transformed = matrix * SIMD4<Float>(corner, 1)
            let point = SIMD3<Float>(transformed.x, transformed.y, transformed.z)
            newMin = simd_min(newMin, point)
            newMax = simd_max(newMax, point)
        }

        return BoundingBox(min: newMin, max: newMax)
    }
}
